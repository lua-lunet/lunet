.PHONY: all build init test clean help
.PHONY: lint build-debug stress release rock rocks-validate certs smoke socket-gc luajit-asan build-debug-asan-luajit repro-50-asan-luajit

LUA ?= lua

all: build ## Build the project (default)

# =============================================================================
# Build Targets (xmake)
# =============================================================================

build: lint ## Build lunet shared library and executable with xmake
	@echo "=== Building lunet with xmake (release mode) ==="
	xmake f -m release --lunet_trace=n --lunet_verbose_trace=n -y
	xmake build
	@echo ""
	@echo "Build complete:"
	@echo "  Module: $$(find build -path '*/release/lunet.so' -type f 2>/dev/null | head -1)"
	@echo "  Binary: $$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)"

build-debug: lint ## Build with LUNET_TRACE=ON for debugging (enables safety assertions)
	@echo "=== Building lunet with xmake (debug mode with tracing) ==="
	@echo "This build includes zero-cost tracing that will:"
	@echo "  - Track coroutine reference create/release balance"
	@echo "  - Verify stack integrity after coroutine checks"
	@echo "  - CRASH on bugs (that's the point - find them early!)"
	@echo ""
	xmake f -m debug --lunet_trace=y --lunet_verbose_trace=n -y
	xmake build
	@echo ""
	@echo "Build complete:"
	@echo "  Module: $$(find build -path '*/debug/lunet.so' -type f 2>/dev/null | head -1)"
	@echo "  Binary: $$(find build -path '*/debug/lunet-run' -type f 2>/dev/null | head -1)"

# =============================================================================
# Quality Assurance
# =============================================================================

lint: ## Check C code for unsafe _lunet_* calls (must use safe wrappers)
	@echo "=== Linting C code for safety violations ==="
	@command -v luarocks >/dev/null 2>&1 || { echo >&2 "Error: luarocks not found. Please install it."; exit 1; }
	@eval $$(luarocks path) && $(LUA) bin/lint_c_safety.lua

init: ## Install dev dependencies (busted, luacheck, luafilesystem) - run once
	@command -v luarocks >/dev/null 2>&1 || { echo >&2 "Error: luarocks not found. Please install it."; exit 1; }
	@echo "Installing dev dependencies..."
	luarocks install luafilesystem --local
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
	@LUNET_BIN=$$(find build -path '*/debug/lunet-run' -type f 2>/dev/null | head -1); \
	if [ -z "$$LUNET_BIN" ]; then echo "Error: lunet binary not found"; exit 1; fi; \
	STRESS_WORKERS=$${STRESS_WORKERS:-50} STRESS_OPS=$${STRESS_OPS:-100} $$LUNET_BIN test/stress_test.lua
	@echo ""
	@echo "=== Stress test completed successfully ==="

socket-gc: build-debug ## Regression test: listener coroutine GC safety (#50)
	@echo ""
	@echo "=== Running socket listener GC regression test ==="
	@LUNET_BIN=$$(find build -path '*/debug/lunet-run' -type f 2>/dev/null | head -1); \
	if [ -z "$$LUNET_BIN" ]; then echo "Error: lunet binary not found"; exit 1; fi; \
	timeout 10 $$LUNET_BIN test/socket_listener_gc.lua

luajit-asan: ## Build Debian Trixie OpenResty LuaJIT with ASan into .tmp
	@echo ""
	@echo "=== Building LuaJIT (Debian Trixie source) with ASan ==="
	@if [ "$$(uname -s)" != "Darwin" ]; then echo "Error: luajit-asan target is macOS-only."; exit 1; fi
	@xmake f -y >/dev/null; \
	LUAJIT_SNAPSHOT=$$(xmake l -c 'import("core.project.config"); config.load(); io.write(config.get("luajit_snapshot") or "")'); \
	LUAJIT_DEBIAN_VERSION=$$(xmake l -c 'import("core.project.config"); config.load(); io.write(config.get("luajit_debian_version") or "")'); \
	echo "LUAJIT_SNAPSHOT=$$LUAJIT_SNAPSHOT"; \
	echo "LUAJIT_DEBIAN_VERSION=$$LUAJIT_DEBIAN_VERSION"; \
	LUAJIT_SNAPSHOT="$$LUAJIT_SNAPSHOT" \
	LUAJIT_DEBIAN_VERSION="$$LUAJIT_DEBIAN_VERSION" \
	lua bin/build_luajit_asan.lua

build-debug-asan-luajit: luajit-asan ## Build lunet-run with ASan, linked against custom LuaJIT ASan
	@echo ""
	@echo "=== Building lunet-run with ASan + custom LuaJIT ASan ==="
	@if [ "$$(uname -s)" != "Darwin" ]; then echo "Error: build-debug-asan-luajit target is macOS-only."; exit 1; fi
	@xmake f -y >/dev/null; \
	LUAJIT_SNAPSHOT=$$(xmake l -c 'import("core.project.config"); config.load(); io.write(config.get("luajit_snapshot") or "")'); \
	LUAJIT_DEBIAN_VERSION=$$(xmake l -c 'import("core.project.config"); config.load(); io.write(config.get("luajit_debian_version") or "")'); \
	PREFIX=$$(LUAJIT_SNAPSHOT="$$LUAJIT_SNAPSHOT" LUAJIT_DEBIAN_VERSION="$$LUAJIT_DEBIAN_VERSION" lua bin/build_luajit_asan.lua); \
	PKG_CONFIG_PATH="$$PREFIX/lib/pkgconfig:$$PKG_CONFIG_PATH" \
	xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y --asan=y -y; \
	PKG_CONFIG_PATH="$$PREFIX/lib/pkgconfig:$$PKG_CONFIG_PATH" \
	xmake build lunet-bin

repro-50-asan-luajit: build-debug-asan-luajit ## Run issue #50 repro with lunet ASan + LuaJIT ASan
	@echo ""
	@echo "=== Running issue #50 repro with ASan-instrumented LuaJIT ==="
	@TS=$$(date +%Y%m%d_%H%M%S); \
	LOGDIR=".tmp/logs/$$TS"; \
	mkdir -p "$$LOGDIR"; \
	if [ "$$(uname -s)" != "Darwin" ]; then echo "Error: repro-50-asan-luajit target is macOS-only."; exit 1; fi; \
	xmake f -y >/dev/null; \
	LUAJIT_SNAPSHOT=$$(xmake l -c 'import("core.project.config"); config.load(); io.write(config.get("luajit_snapshot") or "")'); \
	LUAJIT_DEBIAN_VERSION=$$(xmake l -c 'import("core.project.config"); config.load(); io.write(config.get("luajit_debian_version") or "")'); \
	PREFIX=$$(LUAJIT_SNAPSHOT="$$LUAJIT_SNAPSHOT" LUAJIT_DEBIAN_VERSION="$$LUAJIT_DEBIAN_VERSION" lua bin/build_luajit_asan.lua); \
	export DYLD_LIBRARY_PATH="$$PREFIX/lib:$$DYLD_LIBRARY_PATH"; \
	LUNET_BIN="$$(pwd)/build/macosx/arm64/debug/lunet-run" \
	ITERATIONS=$${ITERATIONS:-10} REQUESTS=$${REQUESTS:-50} CONCURRENCY=$${CONCURRENCY:-4} WORKERS=$${WORKERS:-4} \
	timeout 180 .tmp/repro-payload/scripts/repro.sh \
		>"$$LOGDIR/repro50-asan-luajit.stdout.log" \
		2>"$$LOGDIR/repro50-asan-luajit.stderr.log"; \
	RC=$$?; \
	echo "logdir=$$LOGDIR"; \
	echo "exit=$$RC"; \
	exit $$RC

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
# Smoke Tests (Database Drivers)
# =============================================================================

smoke: build ## Run database driver smoke tests (SQLite3 required, MySQL/Postgres optional)
	@echo "=== Running DB Driver Smoke Tests ==="
	@LUNET_BIN=$$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1); \
	if [ -z "$$LUNET_BIN" ]; then echo "Error: lunet binary not found"; exit 1; fi; \
	echo ""; \
	echo "--- SQLite3 (required) ---"; \
	$$LUNET_BIN test/smoke_sqlite3.lua || exit 1; \
	echo ""; \
	echo "--- MySQL (optional) ---"; \
	$$LUNET_BIN test/smoke_mysql.lua || true; \
	echo ""; \
	echo "--- PostgreSQL (optional) ---"; \
	$$LUNET_BIN test/smoke_postgres.lua || true; \
	echo ""; \
	echo "=== Smoke tests complete ==="

# =============================================================================
# Development Utilities
# =============================================================================

certs: ## Generate self-signed dev certificates
	bin/generate_dev_certs.sh

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
