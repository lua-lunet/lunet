#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGDIR=".tmp/logs/$TIMESTAMP"
mkdir -p "$LOGDIR" ".tmp"

LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
if [[ -z "$LUNET_BIN" ]]; then
  echo "FAIL: lunet-run not found (build it first)" >&2
  exit 1
fi

CONFIG=".tmp/advisory_lock_config.lua"
READY_HI=".tmp/advisory_lock_node_hi_ready"
READY_LO=".tmp/advisory_lock_node_lo_ready"
TEST_CLIENT="test/item05_test_client.lua"

rm -f "$READY_HI" "$READY_LO" "$CONFIG"

cleanup() {
    if [[ -n "${HI_PID:-}" ]] && kill -0 "$HI_PID" 2>/dev/null; then
        kill -TERM "$HI_PID" 2>/dev/null || true
        wait "$HI_PID" 2>/dev/null || true
    fi
    if [[ -n "${LO_PID:-}" ]] && kill -0 "$LO_PID" 2>/dev/null; then
        kill -TERM "$LO_PID" 2>/dev/null || true
        wait "$LO_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "--- Generating config ---"
timeout 10 "$LUNET_BIN" examples/advisory_lock_cas/config_gen.lua --output "$CONFIG"
if [[ ! -f "$CONFIG" ]]; then
    echo "FAIL: config file not created" >&2
    exit 1
fi

echo "--- Starting HI node ---"
timeout 30 "$LUNET_BIN" examples/advisory_lock_cas/node.lua --hi "$CONFIG" \
    > "$LOGDIR/node_hi.log" 2>&1 &
HI_PID=$!

echo "--- Waiting for HI ready (5s) ---"
for i in $(seq 1 50); do
    [[ -f "$READY_HI" ]] && break
    kill -0 "$HI_PID" 2>/dev/null || { echo "FAIL: HI node exited prematurely"; exit 1; }
    sleep 0.1
done
[[ -f "$READY_HI" ]] || { echo "FAIL: Hi not ready"; exit 1; }

echo "--- Starting LO node ---"
timeout 30 "$LUNET_BIN" examples/advisory_lock_cas/node.lua --lo "$CONFIG" \
    > "$LOGDIR/node_lo.log" 2>&1 &
LO_PID=$!

echo "--- Waiting for LO ready (5s) ---"
for i in $(seq 1 50); do
    [[ -f "$READY_LO" ]] && break
    kill -0 "$LO_PID" 2>/dev/null || { echo "FAIL: LO node exited prematurely"; exit 1; }
    sleep 0.1
done
[[ -f "$READY_LO" ]] || { echo "FAIL: Lo not ready"; exit 1; }

echo "--- Running test client ---"
set +e
timeout 15 "$LUNET_BIN" "$TEST_CLIENT" 2>&1
CLIENT_EXIT=$?
set -e

if [[ "$CLIENT_EXIT" -ne 0 ]]; then
    echo "FAIL: test client exited with code $CLIENT_EXIT" >&2
    echo "--- HI node log ---" >&2
    cat "$LOGDIR/node_hi.log" >&2
    echo "--- LO node log ---" >&2
    cat "$LOGDIR/node_lo.log" >&2
    exit 1
fi

echo "PASS: E2E test passed"
exit 0
