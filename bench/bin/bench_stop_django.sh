#!/bin/sh

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TMP_DIR="$GIT_ROOT/.tmp"
PID_FILE="$TMP_DIR/django_server.pid"
NGINX_PID="$TMP_DIR/django_nginx.pid"

log() {
	echo "[BENCH-DJANGO-STOP] $*"
}

# Stop Django
if [ -f "$PID_FILE" ]; then
	PID=$(cat "$PID_FILE")
	if kill -0 "$PID" 2>/dev/null; then
		log "Stopping Django server (PID: $PID)"
		kill "$PID" 2>/dev/null || true
		rm "$PID_FILE"
	else
		log "Django server not running"
		rm "$PID_FILE"
	fi
fi

# Stop Nginx
if [ -f "$NGINX_PID" ]; then
	PID=$(cat "$NGINX_PID")
	if kill -0 "$PID" 2>/dev/null; then
		log "Stopping Nginx (PID: $PID)"
		kill "$PID" 2>/dev/null || true
		rm "$NGINX_PID"
	else
		log "Nginx not running"
		rm "$NGINX_PID"
	fi
fi

log "Stop command complete"
