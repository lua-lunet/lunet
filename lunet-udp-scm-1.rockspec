rockspec_format = "3.0"
package = "lunet-udp"
version = "scm-1"

source = {
    url = "git://github.com/lua-lunet/lunet.git",
    branch = "main"
}

description = {
    summary = "UDP networking driver for lunet",
    detailed = [[
Coroutine-safe UDP driver for lunet async I/O framework.
Provides the lunet.udp module.

Features:
- Non-blocking send/recv via libuv
- Coroutine-based API (no callbacks)
- High-performance buffer management
    ]],
    homepage = "https://github.com/lua-lunet/lunet",
    license = "MIT",
    labels = { "network", "udp", "async", "lunet" }
}

dependencies = {
    "lua >= 5.1",
    "lunet >= scm-1",
    "luarocks-build-xmake"
}

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
    variables = {
        XMAKE_TARGET = "lunet-udp"
    },
    copy_directories = {}
}
