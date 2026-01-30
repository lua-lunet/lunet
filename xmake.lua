-- Lunet: High-performance coroutine-based async I/O for LuaJIT
-- Build system: xmake with pkg-config for dependency detection
--
-- CRITICAL: Lunet requires LuaJIT (Lua 5.1 C API). PUC Lua 5.2+ is NOT supported.
-- The include/lunet_lua.h header enforces this at compile time.

set_project("lunet")
set_version("0.1.0")
set_languages("c99")

add_rules("mode.debug", "mode.release")

-- Debug tracing option (enables LUNET_TRACE for coroutine debugging)
option("trace")
    set_default(false)
    set_showmenu(true)
    set_description("Enable LUNET_TRACE for coroutine reference tracking")
option_end()

-- Common source files for core lunet
local core_sources = {
    "src/main.c",
    "src/co.c",
    "src/fs.c",
    "src/rt.c",
    "src/signal.c",
    "src/socket.c",
    "src/udp.c",
    "src/stl.c",
    "src/timer.c",
    "src/trace.c"
}

-- Use pkg-config packages on Unix, vcpkg on Windows
if is_plat("windows") then
    -- Windows: vcpkg integration
    add_requires("vcpkg::luajit", {alias = "luajit"})
    add_requires("vcpkg::libuv", {alias = "libuv"})
else
    -- Unix: pkg-config
    add_requires("pkgconfig::luajit", {alias = "luajit"})
    add_requires("pkgconfig::libuv", {alias = "libuv"})
end

-- Shared library target for require("lunet")
target("lunet")
    set_kind("shared")
    
    -- Platform-specific module naming
    set_prefixname("")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end
    
    add_files(core_sources)
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv")

    -- Build as a Lua C module (no CLI entrypoint)
    add_defines("LUNET_NO_MAIN")

    -- macOS: build as a bundle with undefined symbols allowed (for Lua host)
    if is_plat("macosx") then
        add_ldflags("-bundle", "-undefined", "dynamic_lookup", {force = true})
    end
    
    -- Linux: system libs
    if is_plat("linux") then
        -- Ensure pthread types/macros are visible in libuv headers and link correctly.
        -- (Some libc setups require -pthread for pthread_rwlock_t.)
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    
    -- Windows: export the module entry point and system libs
    if is_plat("windows") then
        add_defines("LUNET_BUILDING_DLL")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi")
    end
    
    -- Enable tracing if requested
    if has_config("trace") then
        add_defines("LUNET_TRACE")
    end

-- Standalone executable target for ./lunet script.lua
target("lunet-bin")
    set_kind("binary")
    set_basename("lunet")
    
    add_files(core_sources)
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv")
    
    -- Linux: system libs
    if is_plat("linux") then
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    
    -- Windows: system libs
    if is_plat("windows") then
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi")
    end
    
    -- Enable tracing if requested
    if has_config("trace") then
        add_defines("LUNET_TRACE")
    end
