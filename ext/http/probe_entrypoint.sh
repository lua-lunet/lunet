#!/bin/sh
# Start the happy-path target, wait for the port, run the probe.
set -eu
/opt/lunet/lunet-run /opt/lunet/probe_target.lua &
target_pid=$!
for _ in $(seq 1 50); do
  if nc -z 127.0.0.1 8080 2>/dev/null; then
    break
  fi
  sleep 0.2
done
status=0
dotnet /opt/probe/Http11Probe.Cli.dll --host 127.0.0.1 --port 8080 ${LUNET_PROBE_ARGS:-} || status=$?
kill "$target_pid" 2>/dev/null || true
exit "$status"
