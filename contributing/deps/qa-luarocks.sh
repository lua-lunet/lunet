#!/usr/bin/env bash
set -euo pipefail

LUAJIT_BIN=$(command -v luajit 2>/dev/null || true)
if [[ -z "$LUAJIT_BIN" ]]; then
    echo "ERROR: luajit not found on PATH. Install it first:" >&2
    echo "  macOS:   brew install luajit" >&2
    echo "  Debian:  sudo apt-get install luajit libluajit-5.1-dev" >&2
    exit 1
fi

LUAJIT_PREFIX="$(dirname "$(dirname "$LUAJIT_BIN")")"

echo "Installing luarocks QA tools against luajit at $LUAJIT_PREFIX ..."

luarocks --lua-version=5.1 --lua-dir="$LUAJIT_PREFIX" install luafilesystem
luarocks --lua-version=5.1 --lua-dir="$LUAJIT_PREFIX" install busted
luarocks --lua-version=5.1 --lua-dir="$LUAJIT_PREFIX" install luacheck

LUAHECK_CANDIDATES=(
    "$HOME/.luarocks/bin/luacheck"
    "$(command -v luacheck 2>/dev/null || true)"
)

LUAHECK_BIN=""
for candidate in "${LUAHECK_CANDIDATES[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        LUAHECK_BIN="$candidate"
        break
    fi
done

if [[ -z "$LUAHECK_BIN" ]]; then
    echo "ERROR: luacheck installed but binary not found." >&2
    echo "Add ~/.luarocks/bin to your PATH:" >&2
    echo "  export PATH=\"\$HOME/.luarocks/bin:\$PATH\"" >&2
    exit 1
fi

"$LUAHECK_BIN" --version

echo ""
echo "Hint: add ~/.luarocks/bin to PATH if not already:"
echo "  export PATH=\"\$HOME/.luarocks/bin:\$PATH\""
