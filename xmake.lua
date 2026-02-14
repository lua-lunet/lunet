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
-- These are consumed by xmake luajit-asan tasks via project config.
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

-- Address Sanitizer option for debugging memory bugs
option("asan")
    set_default(false)
    set_showmenu(true)
    set_description("Enable Address Sanitizer (-fsanitize=address or /fsanitize=address)")
    add_deps("lunet_trace")
option_end()

-- EasyMem/easy_memory optional integration
option("easy_memory")
    set_default(false)
    set_showmenu(true)
    set_description("Enable EasyMem allocator backend (optional add-in)")
option_end()

option("easy_memory_experimental")
    set_default(false)
    set_showmenu(true)
    set_description("EXPERIMENTAL: Enable EasyMem in release builds with full diagnostics")
option_end()

option("easy_memory_arena_mb")
    set_default("128")
    set_showmenu(true)
    set_description("EasyMem arena size in MB (default: 128)")
option_end()

package("easy_memory")
    set_kind("library", {headeronly = true})
    set_homepage("https://github.com/EasyMem/easy_memory")
    set_description("Header-only memory management system for C")
    set_license("MIT")
    add_urls("https://github.com/EasyMem/easy_memory.git")
    add_versions("2026.02.14", "a3605f1bf759961b3f03fb00ffc1bfa18476929f")
    on_install(function (package)
        os.cp("easy_memory.h", package:installdir("include"))
    end)
    on_test(function (package)
        assert(package:check_csnippets({test = [[
            #define EASY_MEMORY_IMPLEMENTATION
            #define EM_STATIC
            #include <easy_memory.h>
            void test(void) {
                EM *em = em_create(4096);
                if (em) em_destroy(em);
            }
        ]]}, {configs = {languages = "c99"}}))
    end)
package_end()

local function lunet_easy_memory_enabled()
    return has_config("easy_memory")
        or has_config("easy_memory_experimental")
        or has_config("lunet_trace")
        or has_config("asan")
end

local function lunet_easy_memory_diagnostics_enabled()
    return has_config("lunet_trace")
        or has_config("asan")
        or has_config("easy_memory_experimental")
end

local function lunet_easy_memory_arena_bytes()
    local arena_mb = tonumber(get_config("easy_memory_arena_mb") or "128") or 128
    if arena_mb < 8 then
        arena_mb = 8
    end
    return math.floor(arena_mb * 1024 * 1024)
end

local function lunet_apply_asan_flags()
    if not has_config("asan") then
        return
    end
    if is_plat("windows") then
        if is_tool("cc", "cl") then
            add_cflags("/fsanitize=address", {force = true})
            add_ldflags("/fsanitize=address", {force = true})
        else
            add_cflags("-fsanitize=address", "-fno-omit-frame-pointer", {force = true})
            add_ldflags("-fsanitize=address", {force = true})
        end
        return
    end
    add_cflags("-fsanitize=address", "-fno-omit-frame-pointer", {force = true})
    add_ldflags("-fsanitize=address", {force = true})
end

local function lunet_apply_easy_memory()
    if not lunet_easy_memory_enabled() then
        return
    end
    add_packages("easy_memory")
    add_defines("LUNET_EASY_MEMORY")
    add_defines(string.format("LUNET_EASY_MEMORY_ARENA_BYTES=%dULL", lunet_easy_memory_arena_bytes()))
    if lunet_easy_memory_diagnostics_enabled() then
        add_defines("LUNET_EASY_MEMORY_DIAGNOSTICS")
    end
end

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

if lunet_easy_memory_enabled() then
    add_requires("easy_memory 2026.02.14")
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
    lunet_apply_asan_flags()
    lunet_apply_easy_memory()

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

-- Standalone executable target for ./lunet-run script.lua
target("lunet-bin")
    set_kind("binary")
    add_rules("lunet.c_safety_lint")
    set_basename("lunet-run")  -- Avoid conflict with lunet/ driver directory
    
    add_files(core_sources)
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv")
    lunet_apply_asan_flags()
    lunet_apply_easy_memory()
    
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
    set_targetdir("$(buildir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end
    
    add_files(core_sources)
    add_files("ext/sqlite3/sqlite3.c")
    add_includedirs("include", "ext/sqlite3", {public = true})
    add_packages("luajit", "libuv", "sqlite3")
    lunet_apply_asan_flags()
    lunet_apply_easy_memory()
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
    set_targetdir("$(buildir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end
    
    add_files(core_sources)
    add_files("ext/mysql/mysql.c")
    add_includedirs("include", "ext/mysql", {public = true})
    add_packages("luajit", "libuv", "mysql")
    lunet_apply_asan_flags()
    lunet_apply_easy_memory()
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
    set_targetdir("$(buildir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end
    
    add_files(core_sources)
    add_files("ext/postgres/postgres.c")
    add_includedirs("include", "ext/postgres", {public = true})
    add_packages("luajit", "libuv", "pq")
    lunet_apply_asan_flags()
    lunet_apply_easy_memory()
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
    set_targetdir("$(buildir)/$(plat)/$(arch)/$(mode)/lunet")
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
    lunet_apply_asan_flags()
    lunet_apply_easy_memory()

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

-- =============================================================================
-- Developer Tasks (xmake-only workflow)
-- =============================================================================

local function lunet_trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lunet_runner_path(mode)
    local runner_name = is_host("windows") and "lunet-run.exe" or "lunet-run"
    local matches = os.files("build/**/" .. mode .. "/" .. runner_name)
    if #matches == 0 then
        raise("lunet runner not found for mode: " .. mode)
    end
    return matches[1]
end

local function lunet_quote(s)
    return "\"" .. tostring(s):gsub("\"", "\\\"") .. "\""
end

local function lunet_new_logdir(osmod, suite)
    local stamp = os.date("%Y%m%d_%H%M%S")
    local base = path.join(".tmp", "logs", stamp)
    if suite and #suite > 0 then
        base = path.join(base, suite)
    end
    local candidate = base
    local idx = 1
    while osmod.isdir(candidate) do
        candidate = base .. "_" .. tostring(idx)
        idx = idx + 1
    end
    if is_host("windows") then
        osmod.execv("cmd", {"/C", "if not exist " .. lunet_quote(candidate) .. " mkdir " .. lunet_quote(candidate)})
    else
        osmod.execv("bash", {"-lc", "mkdir -p " .. lunet_quote(candidate)})
    end
    return candidate
end

local function lunet_exec_logged(osmod, logdir, name, command)
    local logfile = path.join(logdir, name .. ".log")
    print("$ " .. command)
    local wrapped = command .. " > " .. lunet_quote(logfile) .. " 2>&1"
    if is_host("windows") then
        osmod.execv("cmd", {"/C", wrapped})
    else
        osmod.execv("bash", {"-lc", wrapped})
    end
end

task("init")
    set_menu {
        usage = "xmake init",
        description = "Install local Lua QA dependencies via luarocks"
    }
    on_run(function ()
        os.exec("luarocks install luafilesystem --local")
        os.exec("luarocks install busted --local")
        os.exec("luarocks install luacheck --local")
        cprint("${green}Init complete.${clear} Add local rocks bin to PATH if needed.")
    end)
task_end()

task("lint")
    set_menu {
        usage = "xmake lint",
        description = "Run C safety lint checks"
    }
    on_run(function ()
        os.exec("lua bin/lint_c_safety.lua")
    end)
task_end()

task("check")
    set_menu {
        usage = "xmake check",
        description = "Run luacheck static analysis"
    }
    on_run(function ()
        os.exec("luacheck test/ spec/")
    end)
task_end()

task("test")
    set_menu {
        usage = "xmake test",
        description = "Run Lua tests with busted"
    }
    on_run(function ()
        os.exec("busted spec/")
    end)
task_end()

task("build-release")
    set_menu {
        usage = "xmake build-release",
        description = "Configure and build release profile"
    }
    on_run(function ()
        os.exec("xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y")
        os.exec("xmake build")
    end)
task_end()

task("build-debug")
    set_menu {
        usage = "xmake build-debug",
        description = "Configure and build debug trace profile"
    }
    on_run(function ()
        os.exec("xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y")
        os.exec("xmake build")
    end)
task_end()

task("build-easy-memory-experimental")
    set_menu {
        usage = "xmake build-easy-memory-experimental",
        description = "Configure and build EasyMem experimental release profile"
    }
    on_run(function ()
        local arena_mb = os.getenv("EASY_MEMORY_ARENA_MB") or "128"
        os.exec("xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory_experimental=y --easy_memory_arena_mb=" .. arena_mb .. " -y")
        os.exec("xmake build")
    end)
task_end()

task("preflight-easy-memory")
    set_menu {
        usage = "xmake preflight-easy-memory",
        description = "Run local EasyMem+ASan preflight smoke with logs"
    }
    on_run(function ()
        local ops = os.getenv("LIGHT_DB_STRESS_OPS") or "20"
        local logdir = lunet_new_logdir(os, "easy_memory_preflight")
        print("EasyMem preflight logs: " .. logdir)

        lunet_exec_logged(os, logdir, "01_configure_debug_easy_memory_asan",
            "xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n --asan=y --easy_memory=y -y")
        lunet_exec_logged(os, logdir, "02_build_lunet_bin", "xmake build lunet-bin")
        lunet_exec_logged(os, logdir, "03_build_lunet_sqlite3", "xmake build lunet-sqlite3")
        lunet_exec_logged(os, logdir, "04_build_lunet_mysql", "xmake build lunet-mysql")
        lunet_exec_logged(os, logdir, "05_build_lunet_postgres", "xmake build lunet-postgres")

        local runner = lunet_runner_path("debug")
        local runnerq = lunet_quote(runner)
        if is_host("windows") then
            lunet_exec_logged(os, logdir, "06_ci_easy_memory_db_stress",
                "set ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 && set LIGHT_DB_STRESS_OPS=" .. ops .. " && " .. runnerq .. " test/ci_easy_memory_db_stress.lua")
            lunet_exec_logged(os, logdir, "07_ci_easy_memory_lsan_regression",
                "set ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 && " .. runnerq .. " test/ci_easy_memory_lsan_regression.lua")
        else
            lunet_exec_logged(os, logdir, "06_ci_easy_memory_db_stress",
                "ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 LIGHT_DB_STRESS_OPS=" .. ops .. " timeout 120 " .. runnerq .. " test/ci_easy_memory_db_stress.lua")
            lunet_exec_logged(os, logdir, "07_ci_easy_memory_lsan_regression",
                "ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 timeout 120 " .. runnerq .. " test/ci_easy_memory_lsan_regression.lua")
        end

        print("EasyMem preflight passed. Logs: " .. logdir)
    end)
task_end()

task("stress")
    set_menu {
        usage = "xmake stress",
        description = "Run stress test with debug trace profile"
    }
    on_run(function ()
        local workers = os.getenv("STRESS_WORKERS") or "50"
        local ops = os.getenv("STRESS_OPS") or "100"
        os.exec("xmake build-debug")
        local runner = lunet_runner_path("debug")
        os.execv(runner, {"test/stress_test.lua"}, {envs = {STRESS_WORKERS = workers, STRESS_OPS = ops}})
    end)
task_end()

task("socket-gc")
    set_menu {
        usage = "xmake socket-gc",
        description = "Run socket listener GC regression test"
    }
    on_run(function ()
        os.exec("xmake build-debug")
        local runner = lunet_runner_path("debug")
        if is_host("windows") then
            os.exec("\"" .. runner .. "\" test/socket_listener_gc.lua")
        else
            os.exec("timeout 10 \"" .. runner .. "\" test/socket_listener_gc.lua")
        end
    end)
task_end()

task("smoke")
    set_menu {
        usage = "xmake smoke",
        description = "Run database smoke tests"
    }
    on_run(function ()
        os.exec("xmake build-release")
        local runner = lunet_runner_path("release")
        os.execv(runner, {"test/smoke_sqlite3.lua"})
        pcall(function () os.execv(runner, {"test/smoke_mysql.lua"}) end)
        pcall(function () os.execv(runner, {"test/smoke_postgres.lua"}) end)
    end)
task_end()

task("luajit-asan")
    set_menu {
        usage = "xmake luajit-asan",
        description = "Build macOS LuaJIT ASan into .tmp"
    }
    on_run(function ()
        if not is_host("macosx") then
            raise("luajit-asan task is macOS-only")
        end
        os.exec("xmake f -y >/dev/null")
        local snapshot = lunet_trim(os.iorun("xmake l -c 'import(\"core.project.config\"); config.load(); io.write(config.get(\"luajit_snapshot\") or \"\")'"))
        local debver = lunet_trim(os.iorun("xmake l -c 'import(\"core.project.config\"); config.load(); io.write(config.get(\"luajit_debian_version\") or \"\")'"))
        os.exec("LUAJIT_SNAPSHOT=\"" .. snapshot .. "\" LUAJIT_DEBIAN_VERSION=\"" .. debver .. "\" lua bin/build_luajit_asan.lua")
    end)
task_end()

task("build-debug-asan-luajit")
    set_menu {
        usage = "xmake build-debug-asan-luajit",
        description = "Build lunet-bin with ASan + custom LuaJIT ASan (macOS)"
    }
    on_run(function ()
        if not is_host("macosx") then
            raise("build-debug-asan-luajit task is macOS-only")
        end
        os.exec("xmake f -y >/dev/null")
        local snapshot = lunet_trim(os.iorun("xmake l -c 'import(\"core.project.config\"); config.load(); io.write(config.get(\"luajit_snapshot\") or \"\")'"))
        local debver = lunet_trim(os.iorun("xmake l -c 'import(\"core.project.config\"); config.load(); io.write(config.get(\"luajit_debian_version\") or \"\")'"))
        local prefix = lunet_trim(os.iorun("LUAJIT_SNAPSHOT=\"" .. snapshot .. "\" LUAJIT_DEBIAN_VERSION=\"" .. debver .. "\" lua bin/build_luajit_asan.lua"))
        os.exec("PKG_CONFIG_PATH=\"" .. prefix .. "/lib/pkgconfig:$PKG_CONFIG_PATH\" xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y --asan=y -y")
        os.exec("PKG_CONFIG_PATH=\"" .. prefix .. "/lib/pkgconfig:$PKG_CONFIG_PATH\" xmake build lunet-bin")
    end)
task_end()

task("repro-50-asan-luajit")
    set_menu {
        usage = "xmake repro-50-asan-luajit",
        description = "Run issue #50 repro with LuaJIT+Lunet ASan (macOS)"
    }
    on_run(function ()
        if not is_host("macosx") then
            raise("repro-50-asan-luajit task is macOS-only")
        end
        os.exec("xmake build-debug-asan-luajit")
        local snapshot = lunet_trim(os.iorun("xmake l -c 'import(\"core.project.config\"); config.load(); io.write(config.get(\"luajit_snapshot\") or \"\")'"))
        local debver = lunet_trim(os.iorun("xmake l -c 'import(\"core.project.config\"); config.load(); io.write(config.get(\"luajit_debian_version\") or \"\")'"))
        local prefix = lunet_trim(os.iorun("LUAJIT_SNAPSHOT=\"" .. snapshot .. "\" LUAJIT_DEBIAN_VERSION=\"" .. debver .. "\" lua bin/build_luajit_asan.lua"))
        os.exec("DYLD_LIBRARY_PATH=\"" .. prefix .. "/lib:$DYLD_LIBRARY_PATH\" LUNET_BIN=\"$(pwd)/build/macosx/arm64/debug/lunet-run\" ITERATIONS=${ITERATIONS:-10} REQUESTS=${REQUESTS:-50} CONCURRENCY=${CONCURRENCY:-4} WORKERS=${WORKERS:-4} timeout 180 .tmp/repro-payload/scripts/repro.sh")
    end)
task_end()

task("release")
    set_menu {
        usage = "xmake release",
        description = "Run lint + test + stress + EasyMem preflight, then build release"
    }
    on_run(function ()
        os.exec("xmake lint")
        os.exec("xmake test")
        os.exec("xmake stress")
        os.exec("xmake preflight-easy-memory")
        os.exec("xmake build-release")
    end)
task_end()
