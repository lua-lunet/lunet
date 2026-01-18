#!/bin/bash
set -e

BENCH_DIR="${BENCH_DIR:-.}/bench"
DJANGO_DIR="$BENCH_DIR/django-app"
PID_FILE="$BENCH_DIR/.django_server.pid"

log() {
    echo "[BENCH-DJANGO-SERVER] $*"
}

fail() {
    echo "[BENCH-DJANGO-SERVER] ERROR: $*" >&2
    exit 1
}

# Check if already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log "Django server already running (PID: $OLD_PID)"
        echo "$OLD_PID"
        exit 0
    fi
fi

# Ensure setup is done
log "Ensuring Django setup..."
timeout 180 lua bin/bench_setup_django.lua || fail "Setup failed"

if [ ! -d "$DJANGO_DIR" ]; then
    fail "Django directory not found: $DJANGO_DIR"
fi

log "Starting Django development server..."
cd "$DJANGO_DIR"

VENV_PYTHON="venv/bin/python"
if [ ! -f "$VENV_PYTHON" ]; then
    fail "Virtual environment not found at $VENV_PYTHON"
fi

# Start server in background
"$VENV_PYTHON" manage.py runserver 8001 > "$BENCH_DIR/django_server.log" 2>&1 &
PID=$!

log "Waiting for server to be ready..."
TIMEOUT=30
COUNT=0
while [ $COUNT -lt $TIMEOUT ]; do
    if curl -s http://localhost:8001/health > /dev/null 2>&1 || curl -s http://localhost:8001/api/health > /dev/null 2>&1; then
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
