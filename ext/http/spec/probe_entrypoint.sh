#!/bin/sh
# Start the happy-path target, wait for the port, run the probe.
#
# Plain mode (no /out mounted): print the probe table, exit with its status.
#
# Manifest mode (/out mounted and writable): additionally write
# /out/probe-results.json (the raw probe JSON) and /out/probe-manifest.lua,
# the committed expectation manifest: an in-image sha256 block for the
# three http module files, the summary total, and one verdict/status entry
# per probe test.
#   docker build -f ext/http/Dockerfile.http -t lunet-http-probe .
#   docker run --rm -v "$(pwd)/ext/http:/out" lunet-http-probe
set -eu
/opt/lunet/lunet-run /opt/lunet/probe_target.lua &
target_pid=$!
for _ in $(seq 1 50); do
  if nc -z 127.0.0.1 8080 2>/dev/null; then
    break
  fi
  sleep 0.2
done

probe_args=""
manifest_mode=0
if [ -d /out ] && [ -w /out ]; then
  probe_args="--output /out/probe-results.json"
  manifest_mode=1
fi

status=0
dotnet /opt/probe/Http11Probe.Cli.dll --host 127.0.0.1 --port 8080 \
    ${LUNET_PROBE_ARGS:-} $probe_args || status=$?
kill "$target_pid" 2>/dev/null || true

if [ "$manifest_mode" -eq 1 ] && [ -f /out/probe-results.json ]; then
  {
    echo "return {"
    echo "  modules = {"
    for pair in "http.lua:/opt/lunet/lunet/http.lua" \
                "http_context.lua:/opt/lunet/lunet/http_context.lua" \
                "router.lua:/opt/lunet/lunet/http_router.lua"; do
      printf '    ["%s"] = "%s",\n' "${pair%%:*}" \
        "$(sha256sum "${pair#*:}" | cut -d ' ' -f1)"
    done
    echo "  },"
    echo "  total = $(jq -r '.summary.total' /out/probe-results.json),"
    echo "  scored = $(jq -r '.summary.scored' /out/probe-results.json),"
    echo "  passed = $(jq -r '.summary.passed' /out/probe-results.json),"
    echo "  failed = $(jq -r '.summary.failed' /out/probe-results.json),"
    echo "  warnings = $(jq -r '.summary.warnings' /out/probe-results.json),"
    echo "  results = {"
    jq -r '.results[] | "    [" + (.id | tojson) + "] = { verdict = " + (.verdict | tojson) + ", status = " + (if .statusCode != null then (.statusCode | tostring) else ((.connectionState // "") | tojson) end) + " },"' /out/probe-results.json
    echo "  },"
    echo "}"
  } > /out/probe-manifest.lua
fi

exit "$status"
