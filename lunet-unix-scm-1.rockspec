rockspec_format = "3.0"
package = "lunet-unix"
version = "scm-1"

source = {
    url = "git://github.com/lua-lunet/lunet.git",
    branch = "main"
}

description = {
    summary = "Unix domain socket extension for lunet",
    detailed = [[
Unix domain socket (IPC) support for the lunet async I/O framework.
Provides high-performance local inter-process communication via Unix sockets.

Features:
- Non-blocking Unix socket operations via libuv
- Server (listen/accept) and client (connect) support
- Coroutine-safe read/write operations
- Automatic socket file cleanup on close
- Path validation and error handling

Usage:
    local unix = require("lunet.unix")
    local listener = unix.listen("/tmp/my.sock")
    local client = unix.accept(listener)
    local data = unix.read(client)
    unix.write(client, "response")
    unix.close(client)
    unix.close(listener)
    ]],
    homepage = "https://github.com/lua-lunet/lunet",
    license = "MIT",
    labels = { "socket", "unix", "ipc", "async", "lunet" }
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
        XMAKE_TARGET = "lunet-unix"
    },
    copy_directories = {}
}
