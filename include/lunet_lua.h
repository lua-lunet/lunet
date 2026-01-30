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
 * If the include path is wrong (pointing at PUC Lua), this will either:
 * - Fail to find luajit.h (good - obvious error), or
 * - Find lua.h without LUAJIT_VERSION defined (caught by guard below)
 */
#include <luajit.h>

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

/* Now safe to include the rest of the Lua API */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#endif /* LUNET_LUA_H */
