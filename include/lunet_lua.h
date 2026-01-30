/*
 * lunet_lua.h - LuaJIT header wrapper with compile-time guard
 *
 * ALL lunet source files MUST include this header instead of <lua.h> directly.
 * This ensures we NEVER accidentally compile against PUC Lua (5.2, 5.3, 5.4).
 *
 * LuaJIT is pinned at Lua 5.1 API forever. PUC Lua has diverged (lua_resume
 * signature changed in 5.2+, etc.). They are incompatible at the C API level.
 * This guard makes that incompatibility a hard compile error, not a runtime bug.
 */
#ifndef LUNET_LUA_H
#define LUNET_LUA_H

/*
 * Include luajit.h FIRST to get LUAJIT_VERSION defined.
 *
 * Notes:
 * - Unix (Homebrew/Debian): headers usually live directly in the include dir
 *   (e.g. .../include/luajit-2.1/luajit.h, lua.h, lauxlib.h, lualib.h)
 * - Windows (vcpkg): headers are typically nested under a "luajit" directory
 *   (e.g. .../include/luajit/luajit.h, .../include/luajit/lua.h)
 */
#if defined(_WIN32) || defined(__CYGWIN__)
  #if defined(__has_include)
    #if __has_include(<luajit/luajit.h>)
      #include <luajit/luajit.h>
      #include <luajit/lua.h>
      #include <luajit/lauxlib.h>
      #include <luajit/lualib.h>
    #elif __has_include(<luajit.h>)
      #include <luajit.h>
      #include <lua.h>
      #include <lauxlib.h>
      #include <lualib.h>
    #else
      #error "LuaJIT headers not found. Ensure vcpkg luajit is installed and include paths are configured."
    #endif
  #else
    /* Best effort fallback for older preprocessors */
    #include <luajit/luajit.h>
    #include <luajit/lua.h>
    #include <luajit/lauxlib.h>
    #include <luajit/lualib.h>
  #endif
#else
  #include <luajit.h>
  /* Now safe to include the rest of the Lua API */
  #include <lua.h>
  #include <lauxlib.h>
  #include <lualib.h>
#endif

/*
 * HARD GUARD: Reject anything that isn't LuaJIT.
 *
 * If you see this error, your include path is pointing at PUC Lua instead of
 * LuaJIT. Fix your build configuration:
 *
 * macOS (Homebrew):
 *   Include: /opt/homebrew/opt/luajit/include/luajit-2.1
 *   DO NOT USE: /opt/homebrew/include (contains lua -> lua5.4 symlink)
 *
 * Linux (Debian/Ubuntu):
 *   apt install libluajit-5.1-dev
 *   Include: /usr/include/luajit-2.1
 *   DO NOT USE: /usr/include (may have lua5.4 headers)
 *
 * Windows (vcpkg):
 *   vcpkg install luajit:x64-windows
 *   Include path set by vcpkg toolchain
 */
#ifndef LUAJIT_VERSION
#error "Lunet requires LuaJIT. PUC Lua (5.2, 5.3, 5.4) is NOT supported. Check your include paths."
#endif

#endif /* LUNET_LUA_H */
