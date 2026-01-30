rockspec_format = "3.0"
package = "lunet-postgres"
version = "scm-1"

source = {
    url = "git://github.com/lua-lunet/lunet.git",
    branch = "main"
}

description = {
    summary = "PostgreSQL database driver for lunet",
    detailed = [[
Coroutine-safe PostgreSQL driver for lunet async I/O framework.
Provides the lunet.db module with PostgreSQL backend.

Features:
- Non-blocking queries via libuv thread pool
- Prepared statements with parameter binding
- Full PostgreSQL type mapping
- Uses libpq client library
    ]],
    homepage = "https://github.com/lua-lunet/lunet",
    license = "MIT",
    labels = { "database", "postgresql", "postgres", "async", "lunet" }
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
    POSTGRESQL = {
        header = "libpq-fe.h"
    }
}

build = {
    type = "xmake",
    variables = {
        XMAKE_TARGET = "lunet-postgres"
    },
    copy_directories = {}
}
