#!/bin/bash

BENCH_DIR="${BENCH_DIR:-.}/bench"
PID_FILE="$BENCH_DIR/.django_server.pid"

log() {
    echo "[BENCH-DJANGO-STOP] $*"
}

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        log "Stopping Django server (PID: $PID)"
        kill "$PID" 2>/dev/null || true
        sleep 1
        # Force kill if needed
        kill -9 "$PID" 2>/dev/null || true
        rm "$PID_FILE"
        log "Django server stopped"
    else
        log "Django server not running"
        rm "$PID_FILE"
    fi
else
    log "No Django server PID file found"
fi
