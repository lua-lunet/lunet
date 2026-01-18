.PHONY: all build deps test clean run stop wui bench-django bench-django-stop help

all: build ## Build the project (default)

build: ## Compile C dependencies using CMake
	mkdir -p build
	cd build && cmake .. && make

deps: ## Install LuaRocks dependencies
	@command -v luarocks >/dev/null 2>&1 || { echo >&2 "Error: luarocks not found. Please install it."; exit 1; }
	@echo "Installing dependencies..."
	luarocks install busted --local
	luarocks install luacheck --local

test: deps ## Run unit tests with busted
	@echo "Running tests..."
	@eval $$(luarocks path --bin) && busted spec/

check: deps ## Run static analysis with luacheck
	@echo "Running static analysis..."
	@eval $$(luarocks path --bin) && luacheck app/

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

bench-django: ## Start Django benchmark environment
	@echo "Starting Django benchmark server..."
	@command -v mise >/dev/null 2>&1 || { echo >&2 "Error: mise required. See https://mise.jdx.dev"; exit 1; }
	@command -v nginx >/dev/null 2>&1 || { echo >&2 "Error: nginx required. brew install nginx"; exit 1; }
	@test -f bin/bench_setup_django.lua || { echo >&2 "Error: bin/bench_setup_django.lua not found"; exit 1; }
	@test -f bin/bench_start_django.sh || { echo >&2 "Error: bin/bench_start_django.sh not found"; exit 1; }
	lua bin/bench_setup_django.lua
	bash bin/bench_start_django.sh
	@echo ""
	@echo "Django benchmark running:"
	@echo "  Frontend: http://localhost:9091"
	@echo "  API:      http://localhost:9090/api"

bench-django-stop: ## Stop Django benchmark environment
	@echo "Stopping Django benchmark server..."
	bash bin/bench_stop_django.sh || true

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
