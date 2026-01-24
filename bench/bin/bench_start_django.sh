#!/bin/sh
set -e

BENCH_DIR=${BENCH_DIR:-"$(pwd)/bench"}
export BENCH_DIR
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TMP_DIR="$GIT_ROOT/.tmp"
DJANGO_DIR="$TMP_DIR/bench/django"
PID_FILE="$TMP_DIR/django_server.pid"
NGINX_PID="$TMP_DIR/django_nginx.pid"

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
		exit 0
	fi
fi

# Ensure setup is done
log "Ensuring Django setup..."
lua bench/bin/bench_setup_django.lua || fail "Setup failed"

if [ ! -d "$DJANGO_DIR" ]; then
	fail "Django directory not found: $DJANGO_DIR"
fi

DJANGO_PORT="${DJANGO_PORT:-9090}"
NGINX_PORT="${NGINX_PORT:-9091}"

log "Starting Django development server on port $DJANGO_PORT..."
cd "$DJANGO_DIR"

VENV_PYTHON="venv/bin/python"
if [ ! -f "$VENV_PYTHON" ]; then
	fail "Virtual environment not found at $VENV_PYTHON"
fi

# Start server in background
"$VENV_PYTHON" manage.py runserver "$DJANGO_PORT" >"$TMP_DIR/django_server.log" 2>&1 &
PID=$!
echo "$PID" >"$PID_FILE"

log "Starting Nginx frontend on port $NGINX_PORT..."
mkdir -p "$TMP_DIR"
cd "$GIT_ROOT"
nginx -p "$GIT_ROOT" -c bench/django/nginx.conf -g "pid $NGINX_PID; worker_processes 1; daemon on;" || log "Nginx start failed (maybe already running?)"

log "Waiting for server to be ready..."
TIMEOUT=30
COUNT=0
while [ $COUNT -lt $TIMEOUT ]; do
	if curl -s --max-time 3 "http://localhost:$DJANGO_PORT/api/tags" >/dev/null 2>&1; then
		log "Server is ready"
		log "Frontend: http://localhost:$NGINX_PORT"
		log "API: http://localhost:$DJANGO_PORT/api"
		exit 0
	fi
	sleep 1
	COUNT=$((COUNT + 1))
done

log "Server started but health check timeout"
exit 0
