.PHONY: all build deps test clean run stop wui benchdeps bench-setup-laravel bench-setup-django bench-start-laravel bench-start-django bench-stop-laravel bench-stop-django bench-stop-all bench-test help

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

# Benchmarking targets
benchdeps: ## Check benchmark dependencies
	@echo "Setting up benchmark dependencies..."
	@mkdir -p bench
	@command -v php >/dev/null 2>&1 || { echo >&2 "Error: PHP 8.2+ required. Install from https://www.php.net"; exit 1; }
	@command -v composer >/dev/null 2>&1 || { echo >&2 "Error: Composer required. Install from https://getcomposer.org"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo >&2 "Error: Python 3.9+ required. Install Python"; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo >&2 "Error: Git required"; exit 1; }
	@command -v curl >/dev/null 2>&1 || { echo >&2 "Error: curl required"; exit 1; }
	@test -f bin/bench_setup_laravel.lua || { echo >&2 "Error: bin/bench_setup_laravel.lua not found"; exit 1; }
	@test -f bin/bench_setup_django.lua || { echo >&2 "Error: bin/bench_setup_django.lua not found"; exit 1; }
	@test -f bin/bench_start_laravel.sh || { echo >&2 "Error: bin/bench_start_laravel.sh not found"; exit 1; }
	@test -f bin/bench_start_django.sh || { echo >&2 "Error: bin/bench_start_django.sh not found"; exit 1; }
	@test -f bin/realworld_tools.lua || { echo >&2 "Error: bin/realworld_tools.lua not found"; exit 1; }
	@echo "All benchmark dependencies and scripts found!"

bench-setup-laravel: benchdeps ## Setup Laravel benchmark app
	@echo "Setting up Laravel benchmark environment..."
	@(command -v timeout >/dev/null 2>&1 && timeout 300 lua bin/bench_setup_laravel.lua) || lua bin/bench_setup_laravel.lua || { echo "Laravel setup failed"; exit 1; }

bench-setup-django: benchdeps ## Setup Django benchmark app
	@echo "Setting up Django benchmark environment..."
	@(command -v timeout >/dev/null 2>&1 && timeout 300 lua bin/bench_setup_django.lua) || lua bin/bench_setup_django.lua || { echo "Django setup failed"; exit 1; }

bench-start-laravel: bench-setup-laravel ## Start Laravel server
	@echo "Starting Laravel server..."
	bash bin/bench_start_laravel.sh

bench-start-django: bench-setup-django ## Start Django server
	@echo "Starting Django server..."
	bash bin/bench_start_django.sh

bench-stop-laravel: ## Stop Laravel server
	@echo "Stopping Laravel server..."
	bash bin/bench_stop_laravel.sh || true

bench-stop-django: ## Stop Django server
	@echo "Stopping Django server..."
	bash bin/bench_stop_django.sh || true

bench-test: bench-start-laravel bench-start-django ## Run benchmark tests against all frameworks
	@echo "Running benchmark tests..."
	@echo ""
	@echo "Testing Laravel (http://localhost:8000)..."
	@(command -v timeout >/dev/null 2>&1 && timeout 30 lua bin/realworld_tools.lua test-all http://localhost:8000) || lua bin/realworld_tools.lua test-all http://localhost:8000 || true
	@echo ""
	@echo "Testing Django (http://localhost:8001)..."
	@(command -v timeout >/dev/null 2>&1 && timeout 30 lua bin/realworld_tools.lua test-all http://localhost:8001) || lua bin/realworld_tools.lua test-all http://localhost:8001 || true

bench-stop-all: ## Stop all benchmark servers and app
	@echo "Stopping benchmark servers..."
	bash bin/bench_stop_laravel.sh || true
	bash bin/bench_stop_django.sh || true
	@echo "Stopping app..."
	bin/stop_server.sh || true
	bin/stop_frontend.sh || true
	@echo "Benchmark servers stopped. NOTE: bench/ directory and test evidence preserved."
	@echo "To view test results, check: bench/laravel_server.log bench/django_server.log"
	@echo "To archive bench/ and restart fresh: mv bench .tmp/bench.$$(date +%Y%m%d_%H%M%S)"

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

