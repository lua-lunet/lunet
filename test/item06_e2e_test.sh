#!/usr/bin/env bash
# Test for Item 06: E2E Harness
set -euo pipefail

cd "$(dirname "$0")/.."

timeout 60 make -C examples/advisory_lock_cas test-e2e
echo "PASS: item06 E2E harness test passed"
exit 0
