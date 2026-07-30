#!/usr/bin/env bash
# Test for Item 04: Node Process Skeleton
set -euo pipefail

LUNET_BIN="./build/macosx/arm64/release/lunet-run"
CONFIG_GEN="examples/advisory_lock_cas/config_gen.lua"
NODE="examples/advisory_lock_cas/node.lua"
CONFIG=".tmp/test_item04_config.lua"
READY_HI=".tmp/advisory_lock_node_hi_ready"
READY_LO=".tmp/advisory_lock_node_lo_ready"
HI_LOG=".tmp/test_item04_hi.log"
LO_LOG=".tmp/test_item04_lo.log"

FAILURES=0

cleanup() {
    if [[ -n "${HI_PID:-}" ]] && kill -0 "$HI_PID" 2>/dev/null; then
        kill -TERM "$HI_PID" 2>/dev/null || true
        wait "$HI_PID" 2>/dev/null || true
    fi
    if [[ -n "${LO_PID:-}" ]] && kill -0 "$LO_PID" 2>/dev/null; then
        kill -TERM "$LO_PID" 2>/dev/null || true
        wait "$LO_PID" 2>/dev/null || true
    fi
    rm -f "$READY_HI" "$READY_LO" "$CONFIG" "$HI_LOG" "$LO_LOG"
}
trap cleanup EXIT

rm -f "$READY_HI" "$READY_LO" "$CONFIG" "$HI_LOG" "$LO_LOG"
mkdir -p .tmp

echo "--- Step 1: Generate config ---"
timeout 10 "$LUNET_BIN" "$CONFIG_GEN" --output "$CONFIG"
if [[ ! -f "$CONFIG" ]]; then
    echo "FAIL: config file not created"
    exit 1
fi
echo "Config generated."

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
echo "HI node ready."

echo "--- Step 4: Assert READY printed for HI ---"
if ! grep -q "^READY role=hi " "$HI_LOG"; then
    echo "FAIL: READY line not found in HI log"
    cat "$HI_LOG"
    FAILURES=$((FAILURES + 1))
else
    echo "HI READY line found."
fi

echo "--- Step 5: Start LO node ---"
"$LUNET_BIN" "$NODE" --lo "$CONFIG" >"$LO_LOG" 2>&1 &
LO_PID=$!

echo "--- Step 6: Poll for LO readiness (5s timeout) ---"
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
echo "LO node ready."

echo "--- Step 7: Send SIGTERM to both nodes ---"
kill -TERM "$HI_PID"
kill -TERM "$LO_PID"

echo "--- Step 8: Assert both exit cleanly (0 or SIGTERM=143) ---"
set +e
wait "$HI_PID" 2>/dev/null
HI_EXIT=$?
wait "$LO_PID" 2>/dev/null
LO_EXIT=$?
set -e

if [[ "$HI_EXIT" -ne 0 && "$HI_EXIT" -ne 143 ]]; then
    echo "FAIL: HI node exited with code $HI_EXIT (expected 0 or 143)"
    FAILURES=$((FAILURES + 1))
else
    echo "HI node exited cleanly (code $HI_EXIT)."
fi
if [[ "$LO_EXIT" -ne 0 && "$LO_EXIT" -ne 143 ]]; then
    echo "FAIL: LO node exited with code $LO_EXIT (expected 0 or 143)"
    FAILURES=$((FAILURES + 1))
else
    echo "LO node exited cleanly (code $LO_EXIT)."
fi

echo "--- Step 9: Assert no Error/FAIL in logs (excluding shell termination messages) ---"
if grep -i "error" "$HI_LOG" 2>/dev/null | grep -v "Terminated"; then
    echo "FAIL: Error found in HI log"
    FAILURES=$((FAILURES + 1))
fi
if grep -i "error" "$LO_LOG" 2>/dev/null | grep -v "Terminated"; then
    echo "FAIL: Error found in LO log"
    FAILURES=$((FAILURES + 1))
fi
if grep -i "^FAIL" "$HI_LOG" 2>/dev/null; then
    echo "FAIL: FAIL found in HI log"
    FAILURES=$((FAILURES + 1))
fi
if grep -i "^FAIL" "$LO_LOG" 2>/dev/null; then
    echo "FAIL: FAIL found in LO log"
    FAILURES=$((FAILURES + 1))
fi

echo "--- Step 10: Verify ports freed ---"
HI_CLIENT_PORT=$(sed -n 's/.*client_port=\([0-9]*\).*/\1/p' "$HI_LOG" | head -1)
LO_CLIENT_PORT=$(sed -n 's/.*client_port=\([0-9]*\).*/\1/p' "$LO_LOG" | head -1)
sleep 0.5
if [[ -n "$HI_CLIENT_PORT" ]] && lsof -i :"$HI_CLIENT_PORT" 2>/dev/null | grep -q UDP; then
    echo "FAIL: HI client port $HI_CLIENT_PORT still in use"
    FAILURES=$((FAILURES + 1))
fi
if [[ -n "$LO_CLIENT_PORT" ]] && lsof -i :"$LO_CLIENT_PORT" 2>/dev/null | grep -q UDP; then
    echo "FAIL: LO client port $LO_CLIENT_PORT still in use"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: all item04 node skeleton tests passed"
exit 0
