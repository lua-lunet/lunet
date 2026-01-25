rockspec_format = "3.0"
package = "lunet-sqlite3"
version = "scm-0"

source = {
   url = "git://github.com/lua-lunet/lunet.git",
   branch = "main"
}

description = {
   summary = "SQLite3 driver for Lunet",
   detailed = [[
SQLite3 database driver for the Lunet networking library.
Provides async database operations using Lunet's coroutine model.

Features:
- Connection pooling with mutex protection
- Parameterized queries (prevents SQL injection)
- Automatic escaping
   ]],
   homepage = "https://github.com/lua-lunet/lunet",
   license = "MIT",
   labels = { "database", "sqlite", "async" }
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
   SQLITE3 = {
      header = "sqlite3.h",
      library = "sqlite3"
   }
}

build = {
   type = "cmake",
   variables = {
      CMAKE_C_FLAGS = "$(CFLAGS)",
      CMAKE_BUILD_TYPE = "Release",
      LUNET_DB = "sqlite3",
      LUNET_TRACE = "OFF",
      LUA_INCDIR = "$(LUA_INCDIR)",
      LIBUV_INCDIR = "$(LIBUV_INCDIR)",
      LIBUV_LIBDIR = "$(LIBUV_LIBDIR)",
      SODIUM_INCDIR = "$(SODIUM_INCDIR)",
      SODIUM_LIBDIR = "$(SODIUM_LIBDIR)",
      SQLITE3_INCDIR = "$(SQLITE3_INCDIR)",
      SQLITE3_LIBDIR = "$(SQLITE3_LIBDIR)",
   },
   install = {
      bin = {
         lunet = "build/lunet"
      }
   }
}
