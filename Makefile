.PHONY: all build init test clean run stop wui init-bench bench-django bench-django-stop help
.PHONY: lint build-debug stress release rock

all: build ## Build the project (default)

# =============================================================================
# Build Targets (xmake)
# =============================================================================

build: lint ## Build lunet shared library and executable with xmake
	@echo "=== Building lunet with xmake (release mode) ==="
	xmake f -m release -y
	xmake build -a
	@echo ""
	@echo "Build complete:"
	@echo "  Module: $$(find build -path '*/release/lunet.so' -type f 2>/dev/null | head -1)"
	@echo "  Binary: $$(find build -path '*/release/lunet' -type f 2>/dev/null | head -1)"

build-debug: lint ## Build with LUNET_TRACE=ON for debugging (enables safety assertions)
	@echo "=== Building lunet with xmake (debug mode with tracing) ==="
	@echo "This build includes zero-cost tracing that will:"
	@echo "  - Track coroutine reference create/release balance"
	@echo "  - Verify stack integrity after coroutine checks"
	@echo "  - CRASH on bugs (that's the point - find them early!)"
	@echo ""
	xmake f -m debug --trace=y -y
	xmake build -a
	@echo ""
	@echo "Build complete:"
	@echo "  Module: $$(find build -path '*/debug/lunet.so' -type f 2>/dev/null | head -1)"
	@echo "  Binary: $$(find build -path '*/debug/lunet' -type f 2>/dev/null | head -1)"

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

check: ## Run static analysis with luacheck on test files
	@eval $$(luarocks path --bin) && command -v luacheck >/dev/null 2>&1 || { echo >&2 "Error: luacheck not found. Run 'make init' first."; exit 1; }
	@eval $$(luarocks path --bin) && luacheck test/ spec/

stress: build-debug ## Run concurrent stress test with tracing enabled
	@echo ""
	@echo "=== Running stress test (debug build with tracing) ==="
	@echo "This spawns many concurrent coroutines to expose race conditions."
	@echo "If tracing detects imbalanced refs or stack corruption, it will CRASH."
	@echo "Config: STRESS_WORKERS=$${STRESS_WORKERS:-50} STRESS_OPS=$${STRESS_OPS:-100}"
	@echo ""
	@# Find the built debug binary (must include LUNET_TRACE)
	@LUNET_BIN=$$(find build -path '*/debug/lunet' -type f 2>/dev/null | head -1); \
	if [ -z "$$LUNET_BIN" ]; then echo "Error: lunet binary not found"; exit 1; fi; \
	STRESS_WORKERS=$${STRESS_WORKERS:-50} STRESS_OPS=$${STRESS_OPS:-100} $$LUNET_BIN test/stress_test.lua
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
	@echo "Archiving build artifacts to .tmp..."
	@TS=$$(date +%Y%m%d_%H%M%S); \
	mkdir -p .tmp; \
	if [ -d build ]; then mv build .tmp/build.$$TS; echo "Moved build -> .tmp/build.$$TS"; \
	else echo "No build/ directory to move."; fi; \
	if [ -d .xmake ]; then mv .xmake .tmp/.xmake.$$TS; echo "Moved .xmake -> .tmp/.xmake.$$TS"; \
	else echo "No .xmake/ directory to move."; fi

rock: lint ## Build and install lunet via LuaRocks
	@echo "=== Building LuaRocks package ==="
	luarocks make lunet-scm-1.rockspec

# Note: Demo app moved to https://github.com/lua-lunet/lunet-realworld-example-app

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
# =============================================================================

rocks-validate: ## Validate rockspec syntax
	@echo "=== Validating rockspecs ==="
	@for spec in *.rockspec; do \
		if [ -f "$$spec" ]; then \
			echo "  Checking $$spec..."; \
			lua -e "dofile('$$spec')" || exit 1; \
		fi; \
	done
	@echo "All rockspecs valid."

# =============================================================================
# Development Utilities
# =============================================================================

certs: ## Generate self-signed dev certificates
	bin/generate_dev_certs.sh

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
