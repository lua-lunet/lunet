#!/bin/sh
# Rig entrypoint: wait for the demo server (shared network namespace via
# compose network_mode), then run the Maelstrom echo workload.
set -eu

TARGET="${MAELSTROM_HEALTH_URL:-http://127.0.0.1:18090/health}"
TIME_LIMIT="${MAELSTROM_TIME_LIMIT:-10}"
NODE_COUNT="${MAELSTROM_NODE_COUNT:-1}"
WORKLOAD="${MAELSTROM_WORKLOAD:-echo}"

echo "[rig] waiting for demo server at ${TARGET} ..."
i=0
while [ "$i" -lt 120 ]; do
  if curl -fsS --max-time 2 -o /dev/null "$TARGET" 2>/dev/null; then
    echo "[rig] server is up"
    break
  fi
  i=$((i + 1))
  sleep 0.5
done
if [ "$i" -ge 120 ]; then
  echo "[rig] server never came up" >&2
  exit 1
fi

echo "[rig] maelstrom test -w ${WORKLOAD} --node-count ${NODE_COUNT} --time-limit ${TIME_LIMIT}"
exec maelstrom test \
  -w "${WORKLOAD}" \
  --bin /app/ext/jsonic/maelstrom/shim.sh \
  --node-count "${NODE_COUNT}" \
  --time-limit "${TIME_LIMIT}" \
  --log-stderr
