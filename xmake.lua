-- Lunet: High-performance coroutine-based async I/O for LuaJIT
-- Build system: xmake with pkg-config for dependency detection
--
-- CRITICAL: Lunet requires LuaJIT (Lua 5.1 C API). PUC Lua 5.2+ is NOT supported.
-- The include/lunet_lua.h header enforces this at compile time.

set_project("lunet")
set_version("0.1.0")
set_languages("c99")

add_rules("mode.debug", "mode.release")

-- Run C safety lint automatically before any target build.
-- This keeps lint enforcement on the standard xmake path (xmake build, xmake run, etc).
local c_safety_lint_ran = false

local function read_text_file(filepath)
    local ok, content
    if is_plat("windows") then
        ok, content = pcall(os.iorunv, "cmd", {"/c", "type", path.translate(filepath)})
    else
        ok, content = pcall(os.iorunv, "cat", {filepath})
    end
    if ok then
        return content
    end
    return nil
end

local function lint_check_file(filepath)
    local filename = path.filename(filepath)

    -- Implementation files / trace internals are allowed to use internal symbols.
    if filename:match("_impl%.c$") or
       filename == "trace.c" or
       filename == "co.c" or
       filename == "trace.h" or
       filename == "co.h" then
        return true, 0
    end

    local content = read_text_file(filepath)
    if not content then
        return true, 0
    end

    local violations = {}
    local line_number = 0
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        line_number = line_number + 1
        local code_part = line:match("^(.-)//") or line:match("^(.-)/%*") or line

        if code_part:match("_lunet_[%w_]+%s*%(") and
           not code_part:match("int%s+_lunet_") and
           not code_part:match("void%s+_lunet_") and
           not code_part:match("luaopen_lunet_") then
            table.insert(violations, {
                line = line_number,
                content = line,
                msg = "Internal call. Use safe wrapper (e.g., lunet_ensure_coroutine)"
            })
        end

        if code_part:match("luaL_ref%s*%(.*LUA_REGISTRYINDEX") then
            table.insert(violations, {
                line = line_number,
                content = line,
                msg = "Unsafe ref creation. Use lunet_coref_create()"
            })
        end

        if code_part:match("luaL_unref%s*%(.*LUA_REGISTRYINDEX") then
            table.insert(violations, {
                line = line_number,
                content = line,
                msg = "Unsafe ref release. Use lunet_coref_release()"
            })
        end
    end

    if #violations > 0 then
        print(string.format("VIOLATION in %s:", filepath))
        for _, v in ipairs(violations) do
            print(string.format("  %d: %s", v.line, v.content:gsub("^%s+", "")))
            print(string.format("     -> %s", v.msg))
        end
        print("")
        return false, #violations
    end

    return true, 0
end

local function run_c_safety_lint_once()
    if c_safety_lint_ran then
        return
    end
    c_safety_lint_ran = true

    local root = os.projectdir()
    local files = {}

    local function collect(pattern)
        for _, f in ipairs(os.files(path.join(root, pattern))) do
            table.insert(files, f)
        end
    end

    collect("src/**.c")
    collect("ext/**.c")
    collect("include/**.h")
    collect("ext/**.h")
    table.sort(files)

    local violations_count = 0
    local files_with_violations = 0
    for _, filepath in ipairs(files) do
        local ok, count = lint_check_file(filepath)
        if not ok then
            files_with_violations = files_with_violations + 1
            violations_count = violations_count + count
        end
    end

    if violations_count > 0 then
        os.raise("C safety lint failed: %d violation(s) in %d file(s)", violations_count, files_with_violations)
    end
end

rule("lunet.c_safety_lint")
    before_build(function ()
        run_c_safety_lint_once()
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
    "src/lunet_mem.c"  -- New memory wrapper implementation
}

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
    add_rules("lunet.c_safety_lint")
    
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
    add_rules("lunet.c_safety_lint")
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
    add_rules("lunet.c_safety_lint")
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
target_end()

-- MySQL driver: require("lunet.mysql")
target("lunet-mysql")
    set_default(false)  -- Only build when explicitly requested
    set_kind("shared")
    add_rules("lunet.c_safety_lint")
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
target_end()

-- PostgreSQL driver: require("lunet.postgres")
target("lunet-postgres")
    set_default(false)  -- Only build when explicitly requested
    set_kind("shared")
    add_rules("lunet.c_safety_lint")
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
target_end()

-- PAXE Packet Encryption: require("lunet.paxe")
-- NOTE: PAXE requires libsodium and is only for secure peer-to-peer protocols
-- where the application can handle encryption/decryption details.
-- Depends on: libsodium (libsodium.so/libsodium.dylib/libsodium.dll)
-- Optional via: xmake build lunet-paxe
target("lunet-paxe")
    set_default(false)  -- Only build when explicitly requested
    set_kind("shared")
    add_rules("lunet.c_safety_lint")
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
target_end()
