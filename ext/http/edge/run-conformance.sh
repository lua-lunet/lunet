#!/usr/bin/env bash
# Driver for the edge conformance suite: builds the shared base image once,
# then for each edge variant builds it, runs it against a PostgreSQL, and
# executes conformance.lua (on the lunet runtime) against it from the same
# docker network.
#
# Usage:
#   ext/http/edge/run-conformance.sh [nginx|openresty|traefik|envoy ...]
# With no arguments: all four edges, in that order.
#
# Requires docker (colima on macOS works; the images build native-arch).
set -euo pipefail

cd "$(dirname "$0")"
EDGE_DIR="$PWD"

PGPASSWORD="${PGPASSWORD:-edge-secret}"
NET="lunet-edge-net"
PGHOST="edge-postgres"

run_one() {
    local kind="$1"
    echo "=== edge: ${kind} ==="

    if [ "${kind}" = "openresty" ]; then
        # OpenResty publishes amd64 packages only: build the amd64 base
        # (emulated on Apple Silicon, the realworld-lua precedent) first.
        docker build -q --platform linux/amd64 -f "${EDGE_DIR}/Dockerfile.base" \
            -t lunet-edge-base:amd64 "${EDGE_DIR}"
    fi
    docker build -q -f "${EDGE_DIR}/Dockerfile.${kind}" -t "lunet-edge-${kind}" "$EDGE_DIR"

    docker network create "$NET" 2>/dev/null || true
    docker rm -f "${PGHOST}" "edge-${kind}" 2>/dev/null || true

    docker run -d --name "${PGHOST}" --network "$NET" \
        -e POSTGRES_DB=realworld -e POSTGRES_USER=postgres -e "POSTGRES_PASSWORD=${PGPASSWORD}" \
        postgres:16-alpine

    # RealWorld needs its schema before the API can serve anything.
    sleep 2
    docker exec -i "${PGHOST}" psql -U postgres -d realworld < "${EDGE_DIR}/schema.sql" >/dev/null

    docker run -d --name "edge-${kind}" --network "$NET" \
        -e PGHOST="$PGHOST" -e PGPORT=5432 -e PGDATABASE=realworld \
        -e PGUSER=postgres -e "PGPASSWORD=${PGPASSWORD}" \
        -e JWT_SECRET=edge-conformance-secret \
        -p 28080:80 \
        "lunet-edge-${kind}"

    # The suite runs on the base image's lunet runtime, on the same network.
    # The base image's ENTRYPOINT boots the app + edge, so override it: the
    # suite container must run the suite and nothing else. The edge
    # container's IP is passed for the drip test (lunet's socket.connect
    # takes an address, not a name).
    # Wait for the edge to answer before running the suite (the app boots
    # inside the entrypoint; nginx starts once /health responds).
    for _ in $(seq 1 60); do
        if curl -fsS -o /dev/null http://127.0.0.1:28080/health 2>/dev/null; then
            break
        fi
        sleep 1
    done

    local rc=0
    local edge_ip
    edge_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "edge-${kind}")"
    docker run --rm --network "$NET" \
        --entrypoint sh \
        -v "${EDGE_DIR}/conformance.lua:/suite/conformance.lua:ro" \
        lunet-edge-base \
        -c 'cd /app && exec ./.lunet/*/lunet-run /suite/conformance.lua "$@"' \
        suite "http://edge-${kind}" 80 "${edge_ip}" || rc=$?
    docker rm -f "${PGHOST}" "edge-${kind}" >/dev/null
    return $rc
}

FAILED=0
kinds=("$@")
[ ${#kinds[@]} -eq 0 ] && kinds=(nginx openresty traefik envoy)
for k in "${kinds[@]}"; do
    if ! run_one "$k"; then
        FAILED=1
        echo "=== edge: ${k} FAILED ==="
    fi
done
docker network rm "$NET" >/dev/null 2>&1 || true
exit $FAILED
