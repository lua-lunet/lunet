rockspec_format = "3.0"
package = "lunet-postgres"
version = "scm-0"

source = {
   url = "git://github.com/lua-lunet/lunet.git",
   branch = "main"
}

description = {
   summary = "PostgreSQL driver for Lunet",
   detailed = [[
PostgreSQL database driver for the Lunet networking library.
Provides async database operations using Lunet's coroutine model.

Features:
- Connection pooling with mutex protection
- Parameterized queries (prevents SQL injection)
- Native PostgreSQL escaping
   ]],
   homepage = "https://github.com/lua-lunet/lunet",
   license = "MIT",
   labels = { "database", "postgresql", "postgres", "async" }
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
   POSTGRESQL = {
      header = "libpq-fe.h",
      library = "pq"
   }
}

build = {
   type = "cmake",
   variables = {
      CMAKE_C_FLAGS = "$(CFLAGS)",
      CMAKE_BUILD_TYPE = "Release",
      LUNET_DB = "postgres",
      LUNET_TRACE = "OFF",
      LUA_INCDIR = "$(LUA_INCDIR)",
      LIBUV_INCDIR = "$(LIBUV_INCDIR)",
      LIBUV_LIBDIR = "$(LIBUV_LIBDIR)",
      SODIUM_INCDIR = "$(SODIUM_INCDIR)",
      SODIUM_LIBDIR = "$(SODIUM_LIBDIR)",
      POSTGRESQL_INCDIR = "$(POSTGRESQL_INCDIR)",
      POSTGRESQL_LIBDIR = "$(POSTGRESQL_LIBDIR)",
   },
   install = {
      bin = {
         lunet = "build/lunet"
      }
   }
}
