rockspec_format = "3.0"
package = "lunet-udp"
version = "scm-1"

source = {
    url = "git://github.com/lua-lunet/lunet.git",
    branch = "main"
}

description = {
    summary = "UDP networking extension for lunet",
    detailed = [[
Coroutine-safe UDP networking extension for lunet async I/O framework.
Provides the lunet.udp module for datagram socket operations.

Features:
- Non-blocking UDP send/receive via libuv
- IPv4 and IPv6 support
- Per-socket message queuing
- Zero-copy message delivery
- Zero-cost tracing in debug builds
    ]],
    homepage = "https://github.com/lua-lunet/lunet",
    license = "MIT",
    labels = { "networking", "udp", "async", "lunet" }
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
