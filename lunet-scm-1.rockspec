rockspec_format = "3.0"
package = "lunet"
version = "scm-1"

source = {
    url = "git://github.com/lua-lunet/lunet.git",
    branch = "main"
}

description = {
    summary = "High-performance coroutine-based async I/O for LuaJIT",
    detailed = [[
Lunet is a high-performance coroutine-based network library that integrates
LuaJIT and libuv, enabling elegant async programming without callbacks.

Based on the work by xialeistudio: https://github.com/xialeistudio

Features:
- Coroutine-based async programming (no callbacks)
- TCP/UDP sockets with Unix socket support
- Async filesystem operations
- Timers and signal handling
- Zero-cost tracing for debugging (opt-in)

Database drivers available separately:
- lunet-sqlite3
- lunet-mysql
- lunet-postgres
    ]],
    homepage = "https://github.com/lua-lunet/lunet",
    license = "MIT",
    labels = { "async", "coroutine", "networking", "libuv", "luajit" }
}

dependencies = {
    "lua >= 5.1",
    "luarocks-build-xmake"
}

-- IMPORTANT: Lunet requires LuaJIT (Lua 5.1 C API).
-- 
-- If your LuaRocks is configured for Lua 5.4 (common on macOS Homebrew),
-- you MUST build directly with xmake instead:
--
--   xmake f -m release && xmake build -a
--   # Module: build/macosx/arm64/release/lunet.so
--   # Binary: build/macosx/arm64/release/lunet
--
-- For LuaRocks installation, you need a LuaJIT-configured LuaRocks tree,
-- or pass the LuaJIT include path explicitly:
--
--   luarocks make lunet-scm-1.rockspec \
--     LUAJIT_INCDIR=/opt/homebrew/opt/luajit/include/luajit-2.1

external_dependencies = {
    LUAJIT = {
        header = "luajit.h"
    },
    LIBUV = {
        header = "uv.h"
    }
}

build = {
    type = "xmake",
    copy_directories = {}
}
