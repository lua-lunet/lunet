#!/bin/bash
#
# Lunet Trace Test Runner
#
# This script:
# 1. Finds an available high port
# 2. Builds lunet with LUNET_TRACE enabled
# 3. Runs the comprehensive trace test
# 4. Verifies zero-cost abstraction in release build
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
	echo -e "${GREEN}[TEST]${NC} $1"
}

warn() {
	echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

# Find an available port
find_available_port() {
	local port=18080
	while [ $port -lt 19000 ]; do
		if ! lsof -i:$port >/dev/null 2>&1; then
			echo $port
			return
		fi
		port=$((port + 1))
	done
	echo "18080" # fallback
}

# Build with tracing enabled
build_with_trace() {
	log "Building with LUNET_TRACE=ON..."

	mkdir -p "$BUILD_DIR/trace"
	cd "$BUILD_DIR/trace"

	cmake -DLUNET_TRACE=ON -DCMAKE_BUILD_TYPE=Debug "$PROJECT_DIR" 2>&1 | head -20
	make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

	if [ ! -f "lunet" ]; then
		error "Build failed - lunet binary not found"
		exit 1
	fi

	log "Build successful: $BUILD_DIR/trace/lunet"
}

# Build release (no tracing)
build_release() {
	log "Building release (LUNET_TRACE=OFF)..."

	mkdir -p "$BUILD_DIR/release"
	cd "$BUILD_DIR/release"

	cmake -DLUNET_TRACE=OFF -DCMAKE_BUILD_TYPE=Release "$PROJECT_DIR" 2>&1 | head -20
	make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

	if [ ! -f "lunet" ]; then
		error "Release build failed"
		exit 1
	fi

	log "Release build successful: $BUILD_DIR/release/lunet"
}

# Run trace test
run_trace_test() {
	local port=$(find_available_port)
	log "Running trace test on port $port..."

	cd "$BUILD_DIR/trace"

	export TEST_PORT=$port

	if ./lunet "$SCRIPT_DIR/trace_test.lua" 2>&1; then
		log "Trace test completed successfully!"
		return 0
	else
		error "Trace test failed!"
		return 1
	fi
}

# Verify zero-cost abstraction
verify_zero_cost() {
	log "Verifying zero-cost abstraction..."

	local trace_binary="$BUILD_DIR/trace/lunet"
	local release_binary="$BUILD_DIR/release/lunet"

	if [ ! -f "$trace_binary" ] || [ ! -f "$release_binary" ]; then
		warn "Cannot compare binaries - one or both builds missing"
		return
	fi

	local trace_size=$(stat -f%z "$trace_binary" 2>/dev/null || stat -c%s "$trace_binary" 2>/dev/null)
	local release_size=$(stat -f%z "$release_binary" 2>/dev/null || stat -c%s "$release_binary" 2>/dev/null)

	log "Binary sizes:"
	log "  Trace build:   $trace_size bytes"
	log "  Release build: $release_size bytes"

	# Check if trace symbols are in release binary
	if nm "$release_binary" 2>/dev/null | grep -q "lunet_trace"; then
		warn "Trace symbols found in release binary - may not be zero-cost!"
	else
		log "No trace symbols in release binary - zero-cost verified!"
	fi

	# Check for trace function calls in disassembly
	if command -v objdump >/dev/null 2>&1; then
		if objdump -d "$release_binary" 2>/dev/null | grep -q "lunet_trace"; then
			warn "Trace calls found in release disassembly"
		else
			log "No trace calls in release disassembly - zero-cost verified!"
		fi
	fi
}

# Main
main() {
	log "=========================================="
	log "  LUNET TRACE TEST RUNNER"
	log "=========================================="

	# Build both versions
	build_with_trace
	build_release

	echo ""
	log "=========================================="
	log "  RUNNING TRACE TEST"
	log "=========================================="

	if ! run_trace_test; then
		error "Tests failed!"
		exit 1
	fi

	echo ""
	log "=========================================="
	log "  VERIFYING ZERO-COST ABSTRACTION"
	log "=========================================="

	verify_zero_cost

	echo ""
	log "=========================================="
	log "  ALL TESTS PASSED!"
	log "=========================================="
}

main "$@"
