#!/usr/bin/env bash
# Test for Item 07: Concurrent SET Verification
set -euo pipefail

cd "$(dirname "$0")/.."

LUNET_BIN="./build/macosx/arm64/release/lunet-run"
CONFIG_GEN="examples/advisory_lock_cas/config_gen.lua"
NODE="examples/advisory_lock_cas/node.lua"
TEST_CLIENT="test/item07_test_client.lua"
CONFIG=".tmp/advisory_lock_config.lua"
READY_HI=".tmp/advisory_lock_node_hi_ready"
READY_LO=".tmp/advisory_lock_node_lo_ready"
HI_LOG=".tmp/test_item07_hi.log"
LO_LOG=".tmp/test_item07_lo.log"
CLIENT_LOG=".tmp/test_item07_client.log"

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

rm -f "$READY_HI" "$READY_LO" "$CONFIG" "$HI_LOG" "$LO_LOG" "$CLIENT_LOG"
mkdir -p .tmp

echo "--- Step 1: Generate config ---"
timeout 10 "$LUNET_BIN" "$CONFIG_GEN" --output "$CONFIG"
if [[ ! -f "$CONFIG" ]]; then
    echo "FAIL: config file not created"
    exit 1
fi

echo "--- Step 2: Start HI node ---"
"$LUNET_BIN" "$NODE" --hi "$CONFIG" >"$HI_LOG" 2>&1 &
HI_PID=$!

echo "--- Step 3: Poll for HI readiness (5s timeout) ---"
for i in $(seq 1 50); do
    if [[ -f "$READY_HI" ]]; then break; fi
    if ! kill -0 "$HI_PID" 2>/dev/null; then
        echo "FAIL: HI node exited prematurely"
        cat "$HI_LOG"
        exit 1
    fi
    sleep 0.1
done
if [[ ! -f "$READY_HI" ]]; then
    echo "FAIL: HI readiness file not found after 5s"
    cat "$HI_LOG"
    exit 1
fi

echo "--- Step 4: Start LO node ---"
"$LUNET_BIN" "$NODE" --lo "$CONFIG" >"$LO_LOG" 2>&1 &
LO_PID=$!

echo "--- Step 5: Poll for LO readiness (5s timeout) ---"
for i in $(seq 1 50); do
    if [[ -f "$READY_LO" ]]; then break; fi
    if ! kill -0 "$LO_PID" 2>/dev/null; then
        echo "FAIL: LO node exited prematurely"
        cat "$LO_LOG"
        exit 1
    fi
    sleep 0.1
done
if [[ ! -f "$READY_LO" ]]; then
    echo "FAIL: LO readiness file not found after 5s"
    cat "$LO_LOG"
    exit 1
fi

echo "--- Step 6: Run test client ---"
set +e
timeout 30 "$LUNET_BIN" "$TEST_CLIENT" >"$CLIENT_LOG" 2>&1
CLIENT_EXIT=$?
set -e

cat "$CLIENT_LOG"

if [[ "$CLIENT_EXIT" -ne 0 ]]; then
    echo "FAIL: test client exited with code $CLIENT_EXIT"
    echo "--- HI node log ---"
    cat "$HI_LOG"
    echo "--- LO node log ---"
    cat "$LO_LOG"
    exit 1
fi

echo "--- Step 7: Kill nodes ---"
kill -TERM "$HI_PID" 2>/dev/null || true
kill -TERM "$LO_PID" 2>/dev/null || true
wait "$HI_PID" 2>/dev/null || true
wait "$LO_PID" 2>/dev/null || true
HI_PID=""
LO_PID=""

echo "PASS: item07 concurrent SET verification passed"
exit 0
