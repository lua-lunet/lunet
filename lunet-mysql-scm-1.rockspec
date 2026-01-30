rockspec_format = "3.0"
package = "lunet-mysql"
version = "scm-1"

source = {
    url = "git://github.com/lua-lunet/lunet.git",
    branch = "main"
}

description = {
    summary = "MySQL database driver for lunet",
    detailed = [[
Coroutine-safe MySQL driver for lunet async I/O framework.
Provides the lunet.db module with MySQL/MariaDB backend.

Features:
- Non-blocking queries via libuv thread pool
- Prepared statements with parameter binding
- Full MySQL type mapping
- Compatible with MariaDB
    ]],
    homepage = "https://github.com/lua-lunet/lunet",
    license = "MIT",
    labels = { "database", "mysql", "mariadb", "async", "lunet" }
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
    MYSQL = {
        header = "mysql/mysql.h"
    }
}

build = {
    type = "xmake",
    variables = {
        XMAKE_TARGET = "lunet-mysql"
    },
    copy_directories = {}
}
