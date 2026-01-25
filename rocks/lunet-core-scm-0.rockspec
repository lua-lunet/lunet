rockspec_format = "3.0"
package = "lunet-core"
version = "scm-0"

source = {
   url = "git://github.com/lua-lunet/lunet.git",
   branch = "main"
}

description = {
   summary = "High-performance coroutine-based networking library for LuaJIT",
   detailed = [[
Lunet is a high-performance runtime written in C that integrates LuaJIT and libuv,
focusing on coroutine-driven asynchronous programming. This core package provides:
- Event loop and coroutine management
- TCP/UDP sockets
- Filesystem operations
- Timers and signals
- Crypto (libsodium)

Database drivers are available as separate packages (lunet-sqlite3, lunet-mysql, lunet-postgres).
   ]],
   homepage = "https://github.com/lua-lunet/lunet",
   license = "MIT",
   labels = { "async", "coroutine", "networking", "libuv" }
}

dependencies = {
   "lua >= 5.1"
}

external_dependencies = {
   LIBUV = {
      header = "uv.h",
      library = "uv"
   },
   SODIUM = {
      header = "sodium.h",
      library = "sodium"
   }
}

build = {
   type = "cmake",
   variables = {
      CMAKE_C_FLAGS = "$(CFLAGS)",
      CMAKE_BUILD_TYPE = "Release",
      LUNET_DB = "none",
      LUNET_TRACE = "OFF",
      LUA_INCDIR = "$(LUA_INCDIR)",
      LIBUV_INCDIR = "$(LIBUV_INCDIR)",
      LIBUV_LIBDIR = "$(LIBUV_LIBDIR)",
      SODIUM_INCDIR = "$(SODIUM_INCDIR)",
      SODIUM_LIBDIR = "$(SODIUM_LIBDIR)",
   },
   install = {
      bin = {
         lunet = "build/lunet"
      }
   }
}
