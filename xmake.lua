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

-- EasyMem/easy_memory integration (experimental)
-- Replaces system malloc with easy_memory arena allocator for richer
-- diagnostics, integrity checks, arena-scoped allocation, and profiling.
-- See: https://github.com/EasyMem/easy_memory
option("easy_memory")
    set_default(false)
    set_showmenu(true)
    set_description("Enable EasyMem/easy_memory arena allocator (experimental, richer diagnostics)")
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
    "src/trace.c",
    "src/lunet_mem.c",           -- Memory wrapper implementation
    "src/lunet_easy_memory.c",   -- EasyMem/easy_memory adapter (compiles to nothing unless LUNET_EASY_MEMORY)
    "ext/easy_memory/lunet_easy_memory.c"  -- easy_memory.h implementation TU (compiles to nothing unless LUNET_EASY_MEMORY)
}

-- Helper: apply EasyMem/easy_memory defines and includes to a target.
-- Call inside each target() block after the basic setup.
-- When --easy_memory=y:
--   * LUNET_EASY_MEMORY is always defined
--   * ext/easy_memory is added to include path
--   * Trace builds get EM_ASSERT_STAYS + EM_POISONING + EM_SAFETY_POLICY=0
--   * Release builds get EM_SAFETY_POLICY=1 (defensive)
-- When --asan=y, easy_memory is also force-enabled with full diagnostics.
function apply_easy_memory(is_asan)
    local em_enabled = has_config("easy_memory") or is_asan
    if em_enabled then
        add_includedirs("ext/easy_memory", {public = false})
        add_defines("LUNET_EASY_MEMORY")
        if has_config("lunet_trace") or is_asan then
            -- Full diagnostics: assertions always on, poisoning, contract mode
            add_defines("EM_ASSERT_STAYS")
            add_defines("EM_POISONING")
            add_defines("EM_SAFETY_POLICY=0")
        else
            -- Release: defensive mode, graceful NULL on misuse
            add_defines("EM_SAFETY_POLICY=1")
        end
    end
end

-- =============================================================================
-- Package Requirements (MUST be at root scope, before any targets)
-- =============================================================================

-- Core dependencies (required)
if is_plat("windows") then
    add_requires("vcpkg::luajit", {alias = "luajit"})
    add_requires("vcpkg::libuv", {alias = "libuv"})
else
    add_requires("pkgconfig::luajit", {alias = "luajit"})
    add_requires("pkgconfig::libuv", {alias = "libuv"})
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
        add_defines("_GNU_SOURCE")
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    
    -- Windows: export the module entry point and system libs
    if is_plat("windows") then
        -- Force MSVC to compile .c files as C (not C++).
        add_cflags("/TC")
        add_defines("LUNET_BUILDING_DLL")
        -- libuv on Windows pulls in a number of Win32/COM/security APIs.
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
    end
    
    -- Enable tracing if requested
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
    
    -- EasyMem/easy_memory integration
    apply_easy_memory(false)
target_end()

-- Address Sanitizer option for debugging memory bugs
option("asan")
    set_default(false)
    set_showmenu(true)
    set_description("Enable Address Sanitizer (-fsanitize=address)")
option_end()

-- Standalone executable target for ./lunet-run script.lua
target("lunet-bin")
    set_kind("binary")
    set_basename("lunet-run")  -- Avoid conflict with lunet/ driver directory
    
    add_files(core_sources)
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv")
    
    -- Address Sanitizer support
    if has_config("asan") then
        add_cflags("-fsanitize=address", "-fno-omit-frame-pointer", {force = true})
        add_ldflags("-fsanitize=address", {force = true})
    end
    
    -- Linux: system libs
    if is_plat("linux") then
        add_defines("_GNU_SOURCE")
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    
    -- Windows: system libs
    if is_plat("windows") then
        add_cflags("/TC")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
    end
    
    -- Enable tracing if requested
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
    
    -- EasyMem/easy_memory integration (auto-enabled when ASan is active)
    apply_easy_memory(has_config("asan"))
target_end()

-- =============================================================================
-- Database Driver Modules (separate packages)
-- =============================================================================
-- Each driver registers as lunet.<driver> (e.g., lunet.sqlite3, lunet.mysql, lunet.postgres)
-- Usage: xmake build lunet-sqlite3  (or lunet-mysql, lunet-postgres)
-- Lua:   local db = require("lunet.sqlite3")

-- SQLite3 driver: require("lunet.sqlite3")
target("lunet-sqlite3")
    set_default(false)  -- Only build when explicitly requested
    set_kind("shared")
    set_prefixname("")
    set_basename("sqlite3")  -- Output: lunet/sqlite3.so
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end
    
    add_files(core_sources)
    add_files("ext/sqlite3/sqlite3.c")
    add_includedirs("include", "ext/sqlite3", {public = true})
    add_packages("luajit", "libuv", "sqlite3")
    add_defines("LUNET_NO_MAIN", "LUNET_HAS_DB", "LUNET_DB_SQLITE3")
    
    if is_plat("macosx") then
        add_ldflags("-bundle", "-undefined", "dynamic_lookup", {force = true})
    end
    if is_plat("linux") then
        add_defines("_GNU_SOURCE")
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    if is_plat("windows") then
        add_cflags("/TC")
        add_defines("LUNET_BUILDING_DLL")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
    end
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
    apply_easy_memory(false)
target_end()

-- MySQL driver: require("lunet.mysql")
target("lunet-mysql")
    set_default(false)  -- Only build when explicitly requested
    set_kind("shared")
    set_prefixname("")
    set_basename("mysql")  -- Output: lunet/mysql.so
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end
    
    add_files(core_sources)
    add_files("ext/mysql/mysql.c")
    add_includedirs("include", "ext/mysql", {public = true})
    add_packages("luajit", "libuv", "mysql")
    add_defines("LUNET_NO_MAIN", "LUNET_HAS_DB", "LUNET_DB_MYSQL")
    
    if is_plat("macosx") then
        add_ldflags("-bundle", "-undefined", "dynamic_lookup", {force = true})
    end
    if is_plat("linux") then
        add_defines("_GNU_SOURCE")
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    if is_plat("windows") then
        add_cflags("/TC")
        add_defines("LUNET_BUILDING_DLL")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
    end
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
    apply_easy_memory(false)
target_end()

-- PostgreSQL driver: require("lunet.postgres")
target("lunet-postgres")
    set_default(false)  -- Only build when explicitly requested
    set_kind("shared")
    set_prefixname("")
    set_basename("postgres")  -- Output: lunet/postgres.so
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end
    
    add_files(core_sources)
    add_files("ext/postgres/postgres.c")
    add_includedirs("include", "ext/postgres", {public = true})
    add_packages("luajit", "libuv", "pq")
    add_defines("LUNET_NO_MAIN", "LUNET_HAS_DB", "LUNET_DB_POSTGRES")

    if is_plat("macosx") then
        add_ldflags("-bundle", "-undefined", "dynamic_lookup", {force = true})
    end
    if is_plat("linux") then
        add_defines("_GNU_SOURCE")
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    if is_plat("windows") then
        add_cflags("/TC")
        add_defines("LUNET_BUILDING_DLL")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
    end
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
    apply_easy_memory(false)
target_end()

-- PAXE Packet Encryption: require("lunet.paxe")
-- NOTE: PAXE requires libsodium and is only for secure peer-to-peer protocols
-- where the application can handle encryption/decryption details.
-- Depends on: libsodium (libsodium.so/libsodium.dylib/libsodium.dll)
-- Optional via: xmake build lunet-paxe
target("lunet-paxe")
    set_default(false)  -- Only build when explicitly requested
    set_kind("shared")
    set_prefixname("")
    set_basename("paxe")  -- Output: lunet/paxe.so
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end

    add_files(core_sources)
    add_files("src/paxe.c")
    add_includedirs("include", {public = true})

    -- CRITICAL: Fail fast if libsodium is not available
    add_packages("luajit", "libuv", {public = true})
    add_packages("sodium")  -- Will fail at config time if not found (no optional = true)

    add_defines("LUNET_NO_MAIN", "LUNET_PAXE")

    if is_plat("macosx") then
        add_ldflags("-bundle", "-undefined", "dynamic_lookup", {force = true})
    end
    if is_plat("linux") then
        add_defines("_GNU_SOURCE")
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    if is_plat("windows") then
        add_cflags("/TC")
        add_defines("LUNET_BUILDING_DLL")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
    end
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
    apply_easy_memory(false)
target_end()
