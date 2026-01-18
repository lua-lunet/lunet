#!/bin/bash
set -e

BENCH_DIR="${BENCH_DIR:-.}/bench"
LARAVEL_DIR="$BENCH_DIR/laravel-app"
PID_FILE="$BENCH_DIR/.laravel_server.pid"

log() {
    echo "[BENCH-LARAVEL-SERVER] $*"
}

fail() {
    echo "[BENCH-LARAVEL-SERVER] ERROR: $*" >&2
    exit 1
}

# Check if already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log "Laravel server already running (PID: $OLD_PID)"
        echo "$OLD_PID"
        exit 0
    fi
fi

# Ensure setup is done
log "Ensuring Laravel setup..."
timeout 120 lua bin/bench_setup_laravel.lua || fail "Setup failed"

if [ ! -d "$LARAVEL_DIR" ]; then
    fail "Laravel directory not found: $LARAVEL_DIR"
fi

log "Starting Laravel development server..."
cd "$LARAVEL_DIR"

# Start server in background
php artisan serve --port=8000 > "$BENCH_DIR/laravel_server.log" 2>&1 &
PID=$!

log "Waiting for server to be ready..."
TIMEOUT=30
COUNT=0
while [ $COUNT -lt $TIMEOUT ]; do
    if curl -s http://localhost:8000/health > /dev/null 2>&1 || curl -s http://localhost:8000/api/health > /dev/null 2>&1; then
        log "Server is ready (PID: $PID)"
        echo "$PID" > "$PID_FILE"
        echo "$PID"
        exit 0
    fi
    sleep 1
    COUNT=$((COUNT + 1))
done

log "Server started but health check timeout (PID: $PID)"
echo "$PID" > "$PID_FILE"
echo "$PID"
exit 0
