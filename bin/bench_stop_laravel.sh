#!/bin/bash

BENCH_DIR="${BENCH_DIR:-.}/bench"
PID_FILE="$BENCH_DIR/.laravel_server.pid"

log() {
    echo "[BENCH-LARAVEL-STOP] $*"
}

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        log "Stopping Laravel server (PID: $PID)"
        kill "$PID" 2>/dev/null || true
        sleep 1
        # Force kill if needed
        kill -9 "$PID" 2>/dev/null || true
        rm "$PID_FILE"
        log "Laravel server stopped"
    else
        log "Laravel server not running"
        rm "$PID_FILE"
    fi
else
    log "No Laravel server PID file found"
fi
