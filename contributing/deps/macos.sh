#!/usr/bin/env bash
set -euo pipefail

HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew install pkg-config libuv luajit zlib sqlite3 libsodium curl libpq mysql-client coreutils luarocks lua-language-server

echo ""
echo "=== Keg-only PKG_CONFIG_PATH hint ==="
echo "Add this to your shell profile; required for the db drivers, httpc, and preflight:"
echo ""
echo "  export PKG_CONFIG_PATH=\"\$(brew --prefix zlib)/lib/pkgconfig:\$(brew --prefix curl)/lib/pkgconfig:\$(brew --prefix libpq)/lib/pkgconfig:\$(brew --prefix mysql-client)/lib/pkgconfig:\$PKG_CONFIG_PATH\""
echo ""

exec bash "$(dirname "$0")/qa-luarocks.sh"
