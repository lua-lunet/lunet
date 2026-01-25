.PHONY: all build init test clean run stop wui init-bench bench-django bench-django-stop help
.PHONY: lint build-debug stress release
.PHONY: rocks rock-core rock-sqlite3 rock-mysql rock-postgres rocks-manifest

all: build ## Build the project (default)

LUNET_DB ?= sqlite3

# =============================================================================
# Build Targets
# =============================================================================

build: lint ## Compile C core using CMake (use LUNET_DB=mysql|postgres|sqlite3)
	@echo "=== Building lunet (release mode, LUNET_DB=$(LUNET_DB)) ==="
	mkdir -p build
	cd build && cmake -DLUNET_DB=$(LUNET_DB) -DLUNET_TRACE=OFF .. && make

build-sqlite: ## Build with SQLite3 backend
	$(MAKE) build LUNET_DB=sqlite3

build-postgres: ## Build with PostgreSQL backend
	$(MAKE) build LUNET_DB=postgres

build-mysql: ## Build with MySQL backend
	$(MAKE) build LUNET_DB=mysql

build-debug: lint ## Build with LUNET_TRACE=ON for debugging (enables safety assertions)
	@echo "=== Building lunet (debug mode with tracing, LUNET_DB=$(LUNET_DB)) ==="
	@echo "This build includes zero-cost tracing that will:"
	@echo "  - Track coroutine reference create/release balance"
	@echo "  - Verify stack integrity after coroutine checks"
	@echo "  - CRASH on bugs (that's the point - find them early!)"
	@echo ""
	mkdir -p build
	cd build && cmake -DLUNET_DB=$(LUNET_DB) -DLUNET_TRACE=ON .. && make

# =============================================================================
# Quality Assurance
# =============================================================================

lint: ## Check C code for unsafe _lunet_* calls (must use safe wrappers)
	@echo "=== Linting C code for safety violations ==="
	@lua bin/lint_c_safety.lua

init: ## Install dev dependencies (busted, luacheck) - run once
	@command -v luarocks >/dev/null 2>&1 || { echo >&2 "Error: luarocks not found. Please install it."; exit 1; }
	@echo "Installing dev dependencies..."
	luarocks install busted --local
	luarocks install luacheck --local
	@echo "Done. Run 'make test' to run tests."

test: ## Run unit tests with busted
	@eval $$(luarocks path --bin) && command -v busted >/dev/null 2>&1 || { echo >&2 "Error: busted not found. Run 'make init' first."; exit 1; }
	@eval $$(luarocks path --bin) && busted spec/

check: ## Run static analysis with luacheck
	@eval $$(luarocks path --bin) && command -v luacheck >/dev/null 2>&1 || { echo >&2 "Error: luacheck not found. Run 'make init' first."; exit 1; }
	@eval $$(luarocks path --bin) && luacheck app/

stress: build-debug ## Run concurrent stress test with tracing enabled
	@echo ""
	@echo "=== Running stress test (debug build with tracing) ==="
	@echo "This spawns many concurrent coroutines to expose race conditions."
	@echo "If tracing detects imbalanced refs or stack corruption, it will CRASH."
	@echo "Config: STRESS_WORKERS=$${STRESS_WORKERS:-50} STRESS_OPS=$${STRESS_OPS:-100}"
	@echo ""
	@# Run stress test (config via env vars, defaults: 50 workers x 100 ops)
	STRESS_WORKERS=$${STRESS_WORKERS:-50} STRESS_OPS=$${STRESS_OPS:-100} ./build/lunet test/stress_test.lua
	@echo ""
	@echo "=== Stress test completed successfully ==="

release: lint test stress ## Full release build: lint + test + stress + optimized build
	@echo ""
	@echo "=== All checks passed, building optimized release ==="
	@# Archive the debug build
	@TS=$$(date +%Y%m%d_%H%M%S); \
	if [ -d build ]; then mkdir -p .tmp && mv build .tmp/build.debug.$$TS; fi
	@# Build release
	$(MAKE) build
	@echo ""
	@echo "=== Release build complete ==="
	@echo "Binary: ./build/lunet"

clean: ## Archive build artifacts to .tmp (safe clean)
	@echo "Refusing to rm -rf. Move build to .tmp with timestamp instead."
	@TS=$$(date +%Y%m%d_%H%M%S); \
	if [ -d build ]; then mkdir -p .tmp && mv build .tmp/build.$$TS; echo "Moved build -> .tmp/build.$$TS"; \
	else echo "No build/ directory to move."; fi

# App targets
run: ## Start the API backend
	@echo "Starting RealWorld API Backend..."
	bin/start_server.sh app/main.lua

stop: ## Stop API backend and Frontend
	@echo "Stopping API and Frontend..."
	bin/stop_server.sh || true
	bin/stop_frontend.sh || true

wui: ## Start the React/Vite Frontend
	@echo "Starting RealWorld Frontend..."
	@# Ensure backend is running by checking port 8080
	@lsof -i :8080 -sTCP:LISTEN >/dev/null || { echo "Error: Backend not running. Run 'make run' first."; exit 1; }
	bin/test_with_frontend.sh

# =============================================================================
# Django Benchmark
# Requires: mise with Python 3.12, PostgreSQL with 'conduit' database
# See bench/AGENTS.md for setup details
# =============================================================================

init-bench: ## Initialize benchmark dependencies (mise, python)
	@echo "Initializing benchmark environment..."
	@command -v mise >/dev/null 2>&1 || { echo >&2 "Error: mise required. See https://mise.jdx.dev"; exit 1; }
	mise trust
	mise install python@3.12
	mise use python@3.12
	@echo "Benchmark environment initialized. Python 3.12 ready."

bench-django: ## Start Django benchmark environment
	@echo "Starting Django benchmark server..."
	@command -v mise >/dev/null 2>&1 || { echo >&2 "Error: mise required. See https://mise.jdx.dev"; exit 1; }
	@command -v nginx >/dev/null 2>&1 || { echo >&2 "Error: nginx required. brew install nginx"; exit 1; }
	@test -f bench/bin/bench_setup_django.lua || { echo >&2 "Error: bench/bin/bench_setup_django.lua not found"; exit 1; }
	@test -f bench/bin/bench_start_django.sh || { echo >&2 "Error: bench/bin/bench_start_django.sh not found"; exit 1; }
	lua bench/bin/bench_setup_django.lua
	bench/bin/bench_start_django.sh
	@echo ""
	@echo "Django benchmark running:"
	@echo "  Frontend: http://localhost:9091"
	@echo "  API:      http://localhost:9090/api"

bench-django-stop: ## Stop Django benchmark environment
	@echo "Stopping Django benchmark server..."
	bench/bin/bench_stop_django.sh || true

# =============================================================================
# LuaRocks Package Distribution
# Creates modular rocks for GitHub distribution (Pages/Releases/Packages)
# =============================================================================

rocks: rocks-validate ## Validate all rockspecs
	@echo ""
	@echo "=== Rockspecs validated ==="
	@echo "Rockspecs in: rocks/"
	@ls -1 rocks/*.rockspec

rocks-validate: ## Validate rockspec syntax
	@echo "=== Validating rockspecs ==="
	@for spec in rocks/*.rockspec; do \
		echo "  Checking $$spec..."; \
		lua -e "dofile('$$spec')" || exit 1; \
	done
	@echo "All rockspecs valid."

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
