#!/usr/bin/env sh
#
# Start a Lunet Lua server with evidence capture.
#
# Usage:
#   bin/start_server.sh <lua_file>
#
# Behavior:
# - Kills any existing listener on port 8080 (dev-only)
# - Starts ./build/lunet <lua_file> in background
# - Writes PID and logs under .tmp/logs/YYYYMMDD_HHMMSS_mmm/
# - Verifies port 8080 is listening before returning
LUA_FILE=$1
if [ -z "$LUA_FILE" ]; then
	echo "Usage: $0 <lua_file>"
	exit 1
fi

echo "Cleaning port 8080..."
PIDS=$(lsof -i :8080 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
if [ -n "${PIDS}" ]; then
	for pid in ${PIDS}; do
		kill -9 "$pid" 2>/dev/null || true
	done
fi

TS=$(date +%Y%m%d_%H%M%S)_$$
LOGDIR=".tmp/logs/$TS"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/server.log"
PIDFILE="$LOGDIR/server.pid"

echo "Starting $LUA_FILE..." | tee -a "$LOGFILE"
./build/lunet "$LUA_FILE" >>"$LOGFILE" 2>&1 &
PID=$!
echo $PID >"$PIDFILE"
echo "Server process launched with PID $PID. Logs in $LOGDIR"

echo "Waiting for port 8080 to open..."
i=0
while [ $i -lt 10 ]; do
	if lsof -i :8080 -sTCP:LISTEN >/dev/null; then
		echo "Server is LISTENING on port 8080."
		exit 0
	fi
	if ! ps -p "$PID" >/dev/null 2>&1; then
		echo "Server process died!"
		cat "$LOGFILE"
		exit 1
	fi
	sleep 0.5
	i=$((i + 1))
done

echo "Timed out waiting for port 8080."
cat "$LOGFILE"
exit 1
