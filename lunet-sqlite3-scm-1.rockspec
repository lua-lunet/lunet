rockspec_format = "3.0"
package = "lunet-sqlite3"
version = "scm-1"

source = {
    url = "git://github.com/lua-lunet/lunet.git",
    branch = "main"
}

description = {
    summary = "SQLite3 database driver for lunet",
    detailed = [[
Coroutine-safe SQLite3 driver for lunet async I/O framework.
Provides the lunet.db module with SQLite3 backend.

Features:
- Non-blocking queries via libuv thread pool
- Prepared statements with parameter binding
- Connection pooling friendly (mutex-protected)
- Full SQLite3 type mapping (INTEGER, REAL, TEXT, BLOB, NULL)
    ]],
    homepage = "https://github.com/lua-lunet/lunet",
    license = "MIT",
    labels = { "database", "sqlite", "async", "lunet" }
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
    },
    SQLITE3 = {
        header = "sqlite3.h"
    }
}

build = {
    type = "xmake",
    variables = {
        XMAKE_TARGET = "lunet-sqlite3"
    },
    copy_directories = {}
}
