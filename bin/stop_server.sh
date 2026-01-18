#!/usr/bin/env sh
#
# Stop all running lunet processes (dev-only).
# Evidence is intentionally NOT deleted; logs remain in .tmp/.
#
# Usage:
#   bin/stop_server.sh

pkill -9 lunet 2>/dev/null || true
echo "Killed all lunet processes (if any)."
