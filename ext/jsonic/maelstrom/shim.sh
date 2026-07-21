#!/bin/sh
# Maelstrom --bin entrypoint: runs the stdin/stdout -> HTTP shim under lunet.
exec /app/bin/lunet-run /app/ext/jsonic/maelstrom/shim.lua
