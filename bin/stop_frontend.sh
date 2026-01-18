#!/usr/bin/env sh
#
# Stop the RealWorld frontend process.
#
# Usage:
#   bin/stop_frontend.sh

WUI_ROOT=".tmp/conduit-vite"
PID_FILE="$WUI_ROOT/.frontend.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping frontend (PID $PID)..."
        kill "$PID"
        # Wait a moment
        sleep 1
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID"
        fi
        echo "Frontend stopped."
    else
        echo "Frontend process $PID not running."
    fi
    rm "$PID_FILE"
else
    echo "No frontend PID file found."
fi
