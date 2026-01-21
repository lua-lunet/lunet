#!/usr/bin/env sh
#
# Setup and run the RealWorld Vite React frontend against the local backend.
#
# Usage:
#   bin/test_with_frontend.sh
#
# Behavior:
# - Clones frontend to .tmp/conduit-vite if missing
# - Configures .env.local to point to http://127.0.0.1:8080/api
# - Runs 'bun dev' (or npm fallback) in background
# - Logs to .tmp/logs/YYYYMMDD_HHMMSS/wui.log
# - Saves PID to .tmp/conduit-vite/.frontend.pid

set -e

# Check dependencies
if ! command -v bun >/dev/null 2>&1; then
    echo "WARNING: 'bun' not found. Will attempt to use 'npm'."
    HAS_BUN=0
    if ! command -v npm >/dev/null 2>&1; then
        echo "ERROR: Neither 'bun' nor 'npm' found. Cannot run frontend."
        exit 1
    fi
else
    HAS_BUN=1
fi

WUI_ROOT=".tmp/conduit-vite"
PID_FILE="$WUI_ROOT/.frontend.pid"

# Check if already running
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Frontend already running with PID $PID"
        exit 0
    else
        echo "Found stale PID file. cleaning up..."
        rm "$PID_FILE"
    fi
fi

TS=$(date +%Y%m%d_%H%M%S)
LOGDIR=".tmp/logs/$TS"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/wui.log"

echo "Using log file: $LOGFILE"

if [ -d "$WUI_ROOT" ] && [ ! -f "$WUI_ROOT/package.json" ]; then
    echo "Cleaning broken install..."
    mv "$WUI_ROOT" "$WUI_ROOT.broken.$(date +%s)"
fi

# Setup repo if needed
if [ ! -d "$WUI_ROOT" ]; then
    echo "Setting up frontend in $WUI_ROOT..."
    mkdir -p .tmp
    git clone --depth 1 https://github.com/romansndlr/react-vite-realworld-example-app.git "$WUI_ROOT"
else
    echo "Frontend directory exists at $WUI_ROOT"
fi

# Configure API URL
echo "VITE_API_URL=http://127.0.0.1:8080/api" > "$WUI_ROOT/.env.local"

# Install deps and start
cd "$WUI_ROOT"

echo "Installing dependencies..." | tee -a "../../$LOGFILE"
if [ "$HAS_BUN" -eq 1 ]; then
    rm -f package-lock.json
    bun install >> "../../$LOGFILE" 2>&1
    echo "Starting frontend with bun..." | tee -a "../../$LOGFILE"
    bun dev --host 127.0.0.1 --port 5173 >> "../../$LOGFILE" 2>&1 &
    PID=$!
else
    npm install >> "../../$LOGFILE" 2>&1
    echo "Starting frontend with npm..." | tee -a "../../$LOGFILE"
    npm run dev -- --host 127.0.0.1 --port 5173 >> "../../$LOGFILE" 2>&1 &
    PID=$!
fi

echo "$PID" > ".frontend.pid"
echo "Frontend started with PID $PID. Access at http://127.0.0.1:5173"
