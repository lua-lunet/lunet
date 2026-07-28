#!/usr/bin/env bash
set -euo pipefail

CI=0
QA_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --ci)      CI=1 ;;
        --qa-only) QA_ONLY=1 ;;
        *)         echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [[ "$CI" -eq 1 ]]; then
    SUDO="sudo"
    export DEBIAN_FRONTEND=noninteractive
    EXTRA="--no-install-recommends"
else
    SUDO=""
    EXTRA=""
fi

$SUDO apt-get update

if [[ "$QA_ONLY" -eq 1 ]]; then
    $SUDO apt-get install -y $EXTRA luajit libluajit-5.1-dev luarocks lua5.1
else
    $SUDO apt-get install -y $EXTRA \
        pkg-config libuv1-dev luajit libluajit-5.1-dev \
        zlib1g-dev libsqlite3-dev libsodium-dev libcurl4-openssl-dev \
        libpq-dev default-libmysqlclient-dev luarocks lua5.1 \
        build-essential git curl ca-certificates libasan8
fi

if [[ "$CI" -eq 1 ]]; then
    exec bash "$(dirname "$0")/qa-luarocks.sh" --ci
else
    exec bash "$(dirname "$0")/qa-luarocks.sh"
fi
