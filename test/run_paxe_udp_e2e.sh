#!/usr/bin/env bash
# item14 PERMANENT end-to-end driver: protected UDP over loopback
# between TWO processes (the Rust keystore holds one node identity per
# process). Evolves item09's ad-hoc verification into a runnable
# smoke/CI check.
#   receiver = node 200 (test/paxe_udp_receiver.lua), backgrounded
#   sender   = node 100 (test/paxe_udp_sender.lua), started after ready
#
# Everything is timeout-bound and logged to .tmp/logs/<timestamp>/ per
# the repository rules. A TIMEOUT in either process means a datagram was
# dropped that should not have been, or a receive stalled — diagnose it
# from these logs; do not retry. Exit 0 only if BOTH sides pass.

set -u
cd "$(dirname "$0")/.."
ROOT=$PWD

STAMP=$(date +%Y%m%d_%H%M%S)
LOGDIR="$ROOT/.tmp/logs/$STAMP"
E2E="$ROOT/.tmp/paxe-e2e"
mkdir -p "$LOGDIR" "$E2E"
rm -f "$E2E/ready" "$E2E/ready2" "$E2E/done" "$E2E/result"

LUNET_RUN=$(find "$ROOT/build" -path '*/release/lunet-run' -type f | head -1)
if [ -z "$LUNET_RUN" ]; then
  echo "FAIL: lunet-run release binary not found (build it first)" >&2
  exit 1
fi

export LUNET_PAXE_E2E_DIR="$E2E"

timeout 20 "$LUNET_RUN" test/paxe_udp_receiver.lua > "$LOGDIR/paxe_udp_receiver.log" 2>&1 &
RPID=$!

# Bounded wait (~10s) for the receiver to signal readiness.
i=0
while [ ! -f "$E2E/ready" ] && [ $i -lt 100 ]; do
  kill -0 $RPID 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
if [ ! -f "$E2E/ready" ]; then
  echo "FAIL: receiver never became ready (see $LOGDIR/paxe_udp_receiver.log)" >&2
  kill $RPID 2>/dev/null
  exit 1
fi

timeout 30 "$LUNET_RUN" test/paxe_udp_sender.lua > "$LOGDIR/paxe_udp_sender.log" 2>&1
SRC=$?

# Bounded wait (~10s) for the receiver's verdict file.
i=0
while [ ! -f "$E2E/result" ] && [ $i -lt 100 ]; do
  kill -0 $RPID 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
kill $RPID 2>/dev/null
wait $RPID 2>/dev/null

STATUS=0
if [ $SRC -ne 0 ]; then
  echo "FAIL: sender exited $SRC (see $LOGDIR/paxe_udp_sender.log)" >&2
  STATUS=1
fi
if [ ! -f "$E2E/result" ]; then
  echo "FAIL: receiver produced no verdict (see $LOGDIR/paxe_udp_receiver.log)" >&2
  STATUS=1
elif grep -q "^FAIL" "$E2E/result"; then
  cat "$E2E/result" >&2
  STATUS=1
fi

if [ $STATUS -eq 0 ]; then
  head -1 "$E2E/result"
  echo "paxe udp e2e: PASS (logs in .tmp/logs/$STAMP/)"
fi
exit $STATUS
