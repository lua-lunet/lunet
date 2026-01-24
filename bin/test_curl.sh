#!/usr/bin/env sh
#
# Curl wrapper for Lunet server testing with evidence capture.
#
# Usage:
#   bin/test_curl.sh <curl args...>
#
# Behavior:
# - Refuses to run if port 8080 is not LISTENing
# - Runs curl with --max-time 3
# - Logs stdout/stderr under .tmp/logs/YYYYMMDD_HHMMSS_mmm/curl.log

# Check if port 8080 is open
if ! lsof -i :8080 -sTCP:LISTEN >/dev/null 2>&1; then
	echo "ERROR: Port 8080 is NOT open. Cannot run curl."
	exit 1
fi

TS=$(date +%Y%m%d_%H%M%S)_$$
LOGDIR=".tmp/logs/$TS"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/curl.log"

echo "Running curl with timeout 3s..." | tee -a "$LOGFILE"
curl -v --max-time 3 "$@" >>"$LOGFILE" 2>&1
EXIT_CODE=$?

echo "Curl exit code: $EXIT_CODE" | tee -a "$LOGFILE"
exit $EXIT_CODE
