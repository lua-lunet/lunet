#!/usr/bin/env bash
# Start the app, then the edge. The app binds loopback only (inside the
# container namespace); the edge is the sole externally reachable process.
set -euo pipefail

: "${LUNET_PORT:=8081}"
: "${EDGE_KIND:=nginx}"

# App environment: the pinned realworld start.sh execs lunet-run server.lua.
export LUNET_HOST=127.0.0.1
export LUNET_PORT
cd /app
./start.sh > /var/log/app.log 2>&1 &
APP_PID=$!

# Wait for the app to answer on loopback before the edge goes live.
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${LUNET_PORT}/health" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

echo "[edge] app up (pid ${APP_PID}); starting edge: ${EDGE_KIND}" >&2

case "${EDGE_KIND}" in
    nginx)
        exec nginx -c /etc/nginx/nginx-edge.conf -g "daemon off;"
        ;;
    openresty)
        exec /usr/local/openresty/bin/openresty -c /usr/local/openresty/nginx/conf/nginx-edge.conf -g "daemon off;"
        ;;
    traefik)
        exec traefik --configFile=/etc/traefik/traefik.yml
        ;;
    envoy)
        exec envoy -c /etc/envoy/envoy.yaml --service-cluster edge
        ;;
    *)
        echo "[edge] unknown EDGE_KIND: ${EDGE_KIND}" >&2
        exit 2
        ;;
esac
