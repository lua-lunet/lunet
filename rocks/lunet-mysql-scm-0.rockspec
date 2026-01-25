rockspec_format = "3.0"
package = "lunet-mysql"
version = "scm-0"

source = {
   url = "git://github.com/lua-lunet/lunet.git",
   branch = "main"
}

description = {
   summary = "MySQL driver for Lunet",
   detailed = [[
MySQL/MariaDB database driver for the Lunet networking library.
Provides async database operations using Lunet's coroutine model.

Features:
- Connection pooling with mutex protection
- Parameterized queries (prevents SQL injection)
- Native MySQL escaping
   ]],
   homepage = "https://github.com/lua-lunet/lunet",
   license = "MIT",
   labels = { "database", "mysql", "mariadb", "async" }
}

dependencies = {
   "lua >= 5.1",
   "lunet-core"
}

external_dependencies = {
   LIBUV = {
      header = "uv.h",
      library = "uv"
   },
   SODIUM = {
      header = "sodium.h",
      library = "sodium"
   },
   MYSQL = {
      header = "mysql.h",
      library = "mysqlclient"
   }
}

build = {
   type = "cmake",
   variables = {
      CMAKE_C_FLAGS = "$(CFLAGS)",
      CMAKE_BUILD_TYPE = "Release",
      LUNET_DB = "mysql",
      LUNET_TRACE = "OFF",
      LUA_INCDIR = "$(LUA_INCDIR)",
      LIBUV_INCDIR = "$(LIBUV_INCDIR)",
      LIBUV_LIBDIR = "$(LIBUV_LIBDIR)",
      SODIUM_INCDIR = "$(SODIUM_INCDIR)",
      SODIUM_LIBDIR = "$(SODIUM_LIBDIR)",
      MYSQL_INCDIR = "$(MYSQL_INCDIR)",
      MYSQL_LIBDIR = "$(MYSQL_LIBDIR)",
   },
   install = {
      bin = {
         lunet = "build/lunet"
      }
   }
}
