-- Lunet: High-performance coroutine-based async I/O for LuaJIT
-- Build system: xmake with pkg-config for dependency detection
--
-- CRITICAL: Lunet requires LuaJIT (Lua 5.1 C API). PUC Lua 5.2+ is NOT supported.
-- The include/lunet_lua.h header enforces this at compile time.

set_project("lunet")
set_version("0.2.0")
set_languages("c99")

add_rules("mode.debug", "mode.release")

-- Run C safety lint automatically before any target build.
-- This keeps lint enforcement on the standard xmake path (xmake build, xmake run, etc).
local c_safety_lint_ran = false

rule("lunet.c_safety_lint")
    before_build(function ()
        if c_safety_lint_ran then
            return
        end
        c_safety_lint_ran = true
        local root = os.projectdir()
        local lint_script = path.join(root, "bin", "lint_c_safety.lua")
        os.execv("xmake", {"lua", lint_script}, {curdir = root})
    end)
rule_end()

-- Debug tracing option (enables LUNET_TRACE for coroutine debugging)
-- NOTE: Do not name this option "trace" because xmake reserves --trace.
option("lunet_trace")
    set_default(false)
    set_showmenu(true)
    set_description("Enable LUNET_TRACE for counters, canaries and reference tracking")
option_end()

-- Verbose tracing option (enables LUNET_TRACE_VERBOSE for per-event logging)
option("lunet_verbose_trace")
    set_default(false)
    set_showmenu(true)
    set_description("Enable LUNET_TRACE_VERBOSE for per-event stderr logging")
    add_deps("lunet_trace") -- verbose trace implies trace
option_end()

-- LuaJIT source package pins for the ASan builder script.
-- These are consumed by Makefile luajit-asan targets via xmake config.
option("luajit_snapshot")
    set_default("2.1.0+openresty20250117")
    set_showmenu(true)
    set_description("Debian/OpenResty LuaJIT snapshot identifier (for luajit_*.orig.tar.xz)")
option_end()

option("luajit_debian_version")
    set_default("2.1.0+openresty20250117-2")
    set_showmenu(true)
    set_description("Debian source package version (for luajit_*.dsc and *.debian.tar.xz)")
option_end()

-- Embedded Lua scripts option (release-only, opt-in)
option("lunet_embed_scripts")
    set_default(false)
    set_showmenu(true)
    set_description("Embed a Lua script tree into lunet-run as compressed data (release mode only)")
option_end()

option("lunet_embed_scripts_dir")
    set_default("lua")
    set_showmenu(true)
    set_description("Lua script directory to embed when lunet_embed_scripts is enabled")
option_end()

-- Address Sanitizer option for debugging memory bugs
option("asan")
    set_default(false)
    set_showmenu(true)
    set_description("Enable Address Sanitizer (-fsanitize=address)")
option_end()

local function lunet_apply_trace_defines()
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
end

local function lunet_apply_asan_flags()
    if not has_config("asan") then
        return
    end
    add_cflags("-fsanitize=address", "-fno-omit-frame-pointer", {force = true})
    add_ldflags("-fsanitize=address", {force = true})
end

local function lunet_apply_platform_flags(is_lua_module)
    -- macOS: modules are bundles, core is a dylib (.so filename)
    if is_plat("macosx") and is_lua_module then
        add_ldflags("-bundle", "-undefined", "dynamic_lookup", {force = true})
        add_shflags("-Wl,-rpath,@loader_path/..", {force = true})
    end

    -- Linux: system libs
    if is_plat("linux") then
        add_defines("_GNU_SOURCE")
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
        if is_lua_module then
            add_shflags("-Wl,-rpath,$ORIGIN/..", {force = true})
        end
    end

    -- Windows: system libs
    if is_plat("windows") then
        add_cflags("/TC")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
    end
end

-- Common source files for core lunet (built once, linked by extensions)
local core_sources = {
    "src/lunet_module.c",
    "src/runtime_config.c",
    "src/co.c",
    "src/fs.c",
    "src/rt.c",
    "src/signal.c",
    "src/socket.c",
    "src/udp.c",
    "src/stl.c",
    "src/timer.c",
    "src/trace.c",
    "src/lunet_mem.c"
}

-- =============================================================================
-- Package Requirements (MUST be at root scope, before any targets)
-- =============================================================================

-- Core dependencies (required)
if is_plat("windows") then
    add_requires("vcpkg::luajit", {alias = "luajit"})
    add_requires("vcpkg::libuv", {alias = "libuv"})
    add_requires("vcpkg::zlib", {alias = "zlib", optional = true})
else
    add_requires("pkgconfig::luajit", {alias = "luajit"})
    add_requires("pkgconfig::libuv", {alias = "libuv"})
    add_requires("pkgconfig::zlib", {alias = "zlib", optional = true})
end

-- Database driver dependencies (optional)
-- NOTE: these are optional packages; xmake may prompt to install them.
-- Use `xmake f -y` to auto-confirm.
if is_plat("windows") then
    add_requires("vcpkg::sqlite3", {alias = "sqlite3", optional = true})
    add_requires("vcpkg::libmysql", {alias = "mysql", optional = true})
    add_requires("vcpkg::libpq", {alias = "pq", optional = true})
    add_requires("vcpkg::libsodium", {alias = "sodium", optional = true})
else
    add_requires("pkgconfig::sqlite3", {alias = "sqlite3", optional = true})
    add_requires("pkgconfig::mysqlclient", {alias = "mysql", optional = true})
    add_requires("pkgconfig::libpq", {alias = "pq", optional = true})
    add_requires("pkgconfig::libsodium", {alias = "sodium", optional = true})
end

-- Shared core library for require("lunet") and for linking extensions
target("lunet")
    set_kind("shared")
    add_rules("lunet.c_safety_lint")

    set_prefixname("")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end

    add_files(core_sources)
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv")

    add_defines("LUNET_BUILDING_CORE")
    lunet_apply_asan_flags()
    lunet_apply_trace_defines()
    lunet_apply_platform_flags(false)

    -- macOS: make the dylib discoverable via rpath
    if is_plat("macosx") then
        add_ldflags("-Wl,-install_name,@rpath/lunet.so", {force = true})
    end
target_end()

-- Standalone executable target for ./lunet-run script.lua
target("lunet-bin")
    set_kind("binary")
    add_rules("lunet.c_safety_lint")
    set_basename("lunet-run") -- Avoid conflict with lunet/ driver directory

    add_deps("lunet")
    add_files("src/lunet_cli.c", "src/embed_scripts.c", "src/embed_scripts_blob.c")
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv")

    -- Embedded script packaging (release-only)
    if has_config("lunet_embed_scripts") then
        if not is_mode("release") then
            raise("lunet_embed_scripts is release-only. Reconfigure with: xmake f -m release --lunet_embed_scripts=y")
        end

        add_defines("LUNET_EMBED_SCRIPTS")
        add_packages("zlib")
        add_includedirs(".tmp/generated")

        before_build(function ()
            local root = os.projectdir()
            local generator = path.join(root, "bin", "generate_embed_scripts.lua")
            local source_dir = get_config("lunet_embed_scripts_dir") or "lua"
            local generated_dir = path.join(root, ".tmp", "generated")
            local output = path.join(generated_dir, "lunet_embed_scripts_blob.h")

            os.mkdir(generated_dir)
            os.execv("xmake", {"lua", generator, "--source", source_dir, "--output", output, "--project-root", root}, {curdir = root})
        end)
    end

    if is_plat("macosx") then
        add_ldflags("-Wl,-rpath,@executable_path/.", {force = true})
    end
    if is_plat("linux") then
        add_ldflags("-Wl,-rpath,$ORIGIN", {force = true})
    end

    lunet_apply_asan_flags()
    lunet_apply_trace_defines()
    lunet_apply_platform_flags(false)
target_end()

-- =============================================================================
-- Database Driver Modules (separate packages)
-- =============================================================================
-- Each driver registers as lunet.<driver> (e.g., lunet.sqlite3, lunet.mysql, lunet.postgres)
-- Usage: xmake build lunet-sqlite3  (or lunet-mysql, lunet-postgres)
-- Lua:   local db = require("lunet.sqlite3")

-- SQLite3 driver: require("lunet.sqlite3")
target("lunet-sqlite3")
    set_default(false)
    set_kind("shared")
    add_rules("lunet.c_safety_lint")
    set_prefixname("")
    set_basename("sqlite3")
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
        add_defines("LUNET_BUILDING_MODULE")
    else
        set_extension(".so")
    end

    add_deps("lunet")
    add_files("ext/sqlite3/sqlite3.c")
    add_includedirs("include", "ext/sqlite3", {public = true})
    add_packages("luajit", "libuv", "sqlite3")
    add_defines("LUNET_HAS_DB", "LUNET_DB_SQLITE3")

    lunet_apply_asan_flags()
    lunet_apply_trace_defines()
    lunet_apply_platform_flags(true)
target_end()

-- MySQL driver: require("lunet.mysql")
target("lunet-mysql")
    set_default(false)
    set_kind("shared")
    add_rules("lunet.c_safety_lint")
    set_prefixname("")
    set_basename("mysql")
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
        add_defines("LUNET_BUILDING_MODULE")
    else
        set_extension(".so")
    end

    add_deps("lunet")
    add_files("ext/mysql/mysql.c")
    add_includedirs("include", "ext/mysql", {public = true})
    add_packages("luajit", "libuv", "mysql")
    add_defines("LUNET_HAS_DB", "LUNET_DB_MYSQL")

    lunet_apply_asan_flags()
    lunet_apply_trace_defines()
    lunet_apply_platform_flags(true)
target_end()

-- PostgreSQL driver: require("lunet.postgres")
target("lunet-postgres")
    set_default(false)
    set_kind("shared")
    add_rules("lunet.c_safety_lint")
    set_prefixname("")
    set_basename("postgres")
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
        add_defines("LUNET_BUILDING_MODULE")
    else
        set_extension(".so")
    end

    add_deps("lunet")
    add_files("ext/postgres/postgres.c")
    add_includedirs("include", "ext/postgres", {public = true})
    add_packages("luajit", "libuv", "pq")
    add_defines("LUNET_HAS_DB", "LUNET_DB_POSTGRES")

    lunet_apply_asan_flags()
    lunet_apply_trace_defines()
    lunet_apply_platform_flags(true)
target_end()

-- PAXE Packet Encryption: require("lunet.paxe")
target("lunet-paxe")
    set_default(false)
    set_kind("shared")
    add_rules("lunet.c_safety_lint")
    set_prefixname("")
    set_basename("paxe")
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
        add_defines("LUNET_BUILDING_MODULE")
    else
        set_extension(".so")
    end

    add_deps("lunet")
    add_files("src/paxe.c")
    add_includedirs("include", {public = true})

    add_packages("luajit", "libuv", {public = true})
    add_packages("sodium")

    add_defines("LUNET_PAXE")

    lunet_apply_asan_flags()
    lunet_apply_trace_defines()
    lunet_apply_platform_flags(true)
target_end()
