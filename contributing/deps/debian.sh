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
        zlib1g-dev libsqlite3-dev libcurl4-openssl-dev \
        libpq-dev default-libmysqlclient-dev luarocks lua5.1 \
        build-essential git curl ca-certificates libasan8
    bash "$(dirname "$0")/sodium-src.sh"
fi

# lua-language-server is not in apt; download a pinned release binary.
LUALS_VER="3.15.0"
LUALS_TARBALL="lua-language-server-${LUALS_VER}-linux-x64.tar.gz"
LUALS_URL="https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VER}/${LUALS_TARBALL}"
if ! command -v lua-language-server >/dev/null 2>&1; then
    LUALS_DIR="$(mktemp -d)"
    echo "Installing lua-language-server ${LUALS_VER}..."
    curl --max-time 60 -fsSL "$LUALS_URL" -o "$LUALS_DIR/${LUALS_TARBALL}"
    tar -C "$LUALS_DIR" -xzf "$LUALS_DIR/${LUALS_TARBALL}"
    if [[ "$CI" -eq 1 ]]; then
        # Copy the entire installation directory (not just the binary); the
        # launcher script relies on sibling files such as bootstrap.lua.
        # mktemp creates $LUALS_DIR with 0700; cp -r preserves that, which
        # blocks non-root access to the binary.  Create the destination
        # directory first (inherits system umask, typically 0755), then copy
        # contents into it.
        $SUDO mkdir -p /usr/local/lib/lua-language-server
        $SUDO cp -r "$LUALS_DIR"/. /usr/local/lib/lua-language-server/
        $SUDO ln -sf /usr/local/lib/lua-language-server/bin/lua-language-server /usr/local/bin/lua-language-server
    else
        mkdir -p "$HOME/.local/lib/lua-language-server"
        cp -r "$LUALS_DIR/." "$HOME/.local/lib/lua-language-server/"
        mkdir -p "$HOME/.local/bin"
        ln -sf "$HOME/.local/lib/lua-language-server/bin/lua-language-server" "$HOME/.local/bin/lua-language-server"
        echo "  lua-language-server installed to ~/.local/lib/lua-language-server (add ~/.local/bin to PATH if needed)"
    fi
    rm -rf "$LUALS_DIR"
fi

if [[ "$CI" -eq 1 ]]; then
    exec bash "$(dirname "$0")/qa-luarocks.sh" --ci
else
    exec bash "$(dirname "$0")/qa-luarocks.sh"
fi
