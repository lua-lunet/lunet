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
        local root = os.scriptdir()
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
        or has_config("lunet_trace")
        or has_config("asan")
end

local function lunet_easy_memory_diagnostics_enabled()
    return has_config("lunet_trace")
        or has_config("asan")
end

local function lunet_easy_memory_arena_bytes()
    local arena_mb = tonumber(get_config("easy_memory_arena_mb") or "128") or 128
    if arena_mb < 8 then
        arena_mb = 8
    end
    return math.floor(arena_mb * 1024 * 1024)
end

-- target_kind: "binary" or "shared".
-- On macOS, shared libraries are built as bundles with
-- -undefined dynamic_lookup.  Modern Xcode/ld64 no longer defers ASAN
-- runtime symbol resolution through dynamic_lookup, so ASAN-instrumented
-- object files fail to link.  We skip ASAN entirely (both cflags and
-- ldflags) for macOS shared targets.  The host binary (lunet-bin) is still
-- fully ASAN-instrumented, so memory errors in core code are still caught.
local function lunet_apply_asan_flags(target_kind)
    if not has_config("asan") then
        return
    end
    -- macOS bundles: skip ASAN entirely — compiled .o files reference
    -- __asan_* symbols that the bundle linker cannot resolve.
    if is_plat("macosx") and target_kind == "shared" then
        return
    end
    if is_plat("windows") then
        -- CI uses MSVC on Windows.  is_tool() is not available at
        -- description scope, so we use MSVC flags directly.
        add_cflags("/fsanitize=address", {force = true})
        add_ldflags("/fsanitize=address", {force = true})
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
-- Common source files for core lunet
local core_sources = {
    "src/lunet.c",
    "src/embed_scripts.c",
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
    add_requires("vcpkg::zlib", {alias = "zlib"})
else
    add_requires("pkgconfig::luajit", {alias = "luajit"})
    add_requires("pkgconfig::libuv", {alias = "libuv"})
    add_requires("pkgconfig::zlib", {alias = "zlib"})
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

-- HTTP client dependencies (optional)
if is_plat("windows") then
    add_requires("vcpkg::curl", {alias = "curl", optional = true})
else
    add_requires("pkgconfig::libcurl", {alias = "curl", optional = true})
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

    -- Keep lunet.so for Lua require("lunet"), and also emit liblunet.so so
    -- parent projects using add_deps("lunet") can link via -llunet.
    if not is_plat("windows") then
        after_build(function (target)
            local targetfile = target:targetfile()
            local compat_link_name = "lib" .. target:basename() .. ".so"
            local compat_link_file = path.join(path.directory(targetfile), compat_link_name)
            if compat_link_file ~= targetfile then
                os.tryrm(compat_link_file)
                os.cp(targetfile, compat_link_file)
            end
        end)
    end
    
    add_files(core_sources)
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv", "zlib")
    lunet_apply_asan_flags("shared")
    lunet_apply_easy_memory()

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
        add_defines("LUNET_TEST_FAULTS")
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
    add_files("src/main.c", "src/embed_scripts_blob.c")
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv", "zlib")
    lunet_apply_asan_flags("binary")
    lunet_apply_easy_memory()
    
    -- Embedded script packaging (release-only)
    if has_config("lunet_embed_scripts") then
        if not is_mode("release") then
            raise("lunet_embed_scripts is release-only. Reconfigure with: xmake f -m release --lunet_embed_scripts=y")
        end

        add_defines("LUNET_EMBED_SCRIPTS")
        add_includedirs(".tmp/generated")

        before_build(function ()
            local root = os.projectdir()
            local generator = path.join(root, "bin", "generate_embed_scripts.lua")
            local source_dir = get_config("lunet_embed_scripts_dir") or "lua"
            local generated_dir = path.join(root, ".tmp", "generated")
            local output = path.join(generated_dir, "lunet_embed_scripts_blob.h")

            os.mkdir(generated_dir)
            -- xmake's CLI parser can consume --foo flags unless we force passthrough with "--".
            -- We also provide env fallbacks for compatibility across xmake versions.
            local generator_args = {
                "lua", generator, "--",
                "--source", source_dir,
                "--output", output,
                "--project-root", root
            }
            local generator_envs = {
                LUNET_EMBED_SOURCE = source_dir,
                LUNET_EMBED_OUTPUT = output,
                LUNET_EMBED_PROJECT_ROOT = root
            }
            os.execv("xmake", generator_args, {curdir = root, envs = generator_envs})
        end)
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
        add_defines("LUNET_TEST_FAULTS")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
target_end()

-- Linkable engine for release SDK consumers.  It deliberately excludes the
-- Lunet CLI main() and the compile-time generated application blob.
target("lunet-static")
    set_default(false)
    set_kind("static")
    add_rules("lunet.c_safety_lint")
    add_files(core_sources)
    add_includedirs("include", {public = true})
    add_packages("luajit", "libuv", "zlib", {public = true})
    lunet_apply_easy_memory()
    if is_plat("linux") then
        add_defines("_GNU_SOURCE")
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    if is_plat("windows") then
        add_cflags("/TC")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
    end
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
        add_defines("LUNET_TEST_FAULTS")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
target_end()

target("sdk-api-test")
    set_default(false)
    set_kind("binary")
    add_rules("lunet.c_safety_lint")
    add_files("test/sdk_api.c")
    add_includedirs("include")
    add_deps("lunet-static")
    add_packages("luajit", "libuv", "zlib")
    if is_plat("linux") then
        add_cflags("-pthread")
        add_ldflags("-pthread")
        add_syslinks("pthread", "dl", "m")
    end
    if is_plat("windows") then
        add_cflags("/TC")
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp")
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
    add_packages("luajit", "libuv", "zlib", "sqlite3")
    lunet_apply_asan_flags("shared")
    lunet_apply_easy_memory()
    add_defines("LUNET_HAS_DB", "LUNET_DB_SQLITE3")
    
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
        add_defines("LUNET_TEST_FAULTS")
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
    add_packages("luajit", "libuv", "zlib", "mysql")
    lunet_apply_asan_flags("shared")
    lunet_apply_easy_memory()
    add_defines("LUNET_HAS_DB", "LUNET_DB_MYSQL")
    
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
        -- crypt32/secur32 are required by libcrypto (OpenSSL) which is pulled in
        -- by the MySQL client library on Windows (CAPI/WinCert store backends).
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp", "crypt32", "secur32")
        -- vcpkg libmysql installs mysql.h under include/mysql/, not include/.
        on_load(function (target)
            local vcpkg_root = os.getenv("VCPKG_ROOT")
            if not vcpkg_root then
                return
            end
            local triplet = os.getenv("VCPKG_DEFAULT_TRIPLET") or "x64-windows"
            local mysql_incdir = path.join(vcpkg_root, "installed", triplet, "include", "mysql")
            if os.isdir(mysql_incdir) then
                target:add("includedirs", mysql_incdir)
            end
        end)
    end
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
        add_defines("LUNET_TEST_FAULTS")
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
    add_packages("luajit", "libuv", "zlib", "pq")
    lunet_apply_asan_flags("shared")
    lunet_apply_easy_memory()
    add_defines("LUNET_HAS_DB", "LUNET_DB_POSTGRES")

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
        -- libpq (SSPI/LDAP) and OpenSSL (CAPI/winstore) need these system libs on Windows.
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp", "crypt32", "secur32", "wldap32")
    end
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
        add_defines("LUNET_TEST_FAULTS")
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
    add_packages("luajit", "libuv", "zlib", {public = true})
    add_packages("sodium")  -- Will fail at config time if not found (no optional = true)
    lunet_apply_asan_flags("shared")
    lunet_apply_easy_memory()

    add_defines("LUNET_PAXE")

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
        add_defines("LUNET_TEST_FAULTS")
    end
    if has_config("lunet_verbose_trace") then
        add_defines("LUNET_TRACE_VERBOSE")
    end
target_end()

-- HTTPS client module: require("lunet.httpc")
-- Optional via: xmake build lunet-httpc
target("lunet-httpc")
    set_default(false)
    set_kind("shared")
    add_rules("lunet.c_safety_lint")
    set_prefixname("")
    set_basename("httpc")  -- Output: lunet/httpc.so
    set_targetdir("$(builddir)/$(plat)/$(arch)/$(mode)/lunet")
    if is_plat("windows") then
        set_extension(".dll")
    else
        set_extension(".so")
    end

    add_files(core_sources)
    add_files("ext/httpc/httpc.c")
    add_includedirs("include", "ext/httpc", {public = true})
    add_packages("luajit", "libuv", "zlib", "curl")
    lunet_apply_asan_flags("shared")
    lunet_apply_easy_memory()

    add_defines("LUNET_HTTPC")

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
        add_syslinks("ws2_32", "iphlpapi", "userenv", "psapi", "advapi32", "user32", "shell32", "ole32", "dbghelp", "crypt32", "secur32")
    end
    if has_config("lunet_trace") then
        add_defines("LUNET_TRACE")
        add_defines("LUNET_TEST_FAULTS")
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
        description = "Install Lua QA tools pinned to luajit (delegates to contributing/deps/qa-luarocks.sh)"
    }
    on_run(function ()
        if is_host("windows") then
            os.exec("luarocks install luafilesystem --local")
            os.exec("luarocks install busted --local")
            os.exec("luarocks install luacheck --local")
            cprint("${green}Init complete.${clear} Add local rocks bin to PATH if needed.")
        else
            os.exec("bash contributing/deps/qa-luarocks.sh")
        end
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
        -- Prefer the luarocks user tree: a luacheck installed for the
        -- system Lua (e.g. homebrew lua 5.5, which luacheck 1.2.0 cannot
        -- run under) may shadow a working one on PATH. Install a working
        -- copy with: luarocks --lua-version=5.1 --lua-dir=$(brew --prefix
        -- luajit) install luacheck
        local candidates = {
            path.join(os.getenv("HOME") or "", ".luarocks", "bin", "luacheck"),
            "luacheck",
        }
        local luacheck = nil
        for _, candidate in ipairs(candidates) do
            if candidate == "luacheck" or os.isfile(candidate) then
                local ok = os.execv(candidate, {"--version"}, {try = true})
                if ok == 0 then
                    luacheck = candidate
                    break
                end
            end
        end
        assert(luacheck, "no working luacheck found (see the comment in the check task for install instructions)")
        os.execv(luacheck, {"--config", ".luacheckrc", "test/", "spec/", "examples/", "types/"})
    end)
task_end()

task("test")
    set_menu {
        usage = "xmake test",
        description = "Run type checking then Lua tests with busted"
    }
    on_run(function ()
        -- Type checking runs first; type errors abort before busted.
        os.exec("xmake check-types")
        -- Build the httpc C module up front so httpc_spec can always run.
        -- A platform that cannot build it must surface red here, not skip.
        os.exec("xmake build lunet-httpc")
        local mode = get_config("mode") or "release"
        local dirs = os.dirs("build/**/" .. mode .. "/lunet")
        local cpath = os.getenv("LUA_CPATH") or ""
        if #dirs > 0 then
            local ext = is_host("windows") and "?.dll" or "?.so"
            -- require("lunet.httpc") expands "?" to "lunet/httpc", so the
            -- cpath root must be the PARENT of the lunet/ dir; using the
            -- lunet/ dir itself yields .../lunet/lunet/httpc.so and never
            -- resolves. Keep the old entry too for bare module names.
            local parentdir = path.join(os.projectdir(), path.directory(dirs[1]), ext)
            local moddir = path.join(os.projectdir(), dirs[1], ext)
            cpath = parentdir .. ";" .. moddir .. ";;" .. cpath
        end
        -- busted must run under LuaJIT (5.1 ABI): lunet's C modules link
        -- libluajit-5.1, so loading one into a PUC Lua process puts two
        -- incompatible Lua runtimes in one address space -- it segfaults on
        -- Linux and hangs on macOS. The luarocks-generated `busted` wrapper
        -- cannot be trusted here: it hardcodes whichever interpreter luarocks
        -- detected at install time (`exec /usr/bin/lua5.1 ... bin/busted` on
        -- Debian/Ubuntu even when installed with --lua-dir pointing at
        -- luajit; lua5.5 with Homebrew). Drive busted's Lua entry point with
        -- luajit ourselves instead. Overrides: LUNET_LUAJIT=/path/to/luajit,
        -- LUNET_BUSTED=/path/to/busted-lua-entry.
        local luajit = os.getenv("LUNET_LUAJIT") or "luajit"
        assert(os.execv(luajit, {"-v"}, {try = true, stdout = os.nuldev(), stderr = os.nuldev()}) == 0,
               "luajit not found (" .. luajit .. ") -- the busted suite must run under LuaJIT; " ..
               "install it (Debian: apt-get install luajit, macOS: brew install luajit) " ..
               "or set LUNET_LUAJIT")
        local busted_entry = os.getenv("LUNET_BUSTED")
            or path.join(os.projectdir(), "bin", "busted_runner.lua")
        -- busted itself lives in the luarocks 5.1 trees, which are not on
        -- luajit's default package.path everywhere (Homebrew's luajit resolves
        -- relative to its Cellar prefix), so ask luarocks where they are.
        local lua_path = os.getenv("LUA_PATH")
        local lr_path = try { function ()
            return os.iorunv("luarocks", {"--lua-version=5.1", "path", "--lr-path"})
        end }
        if lr_path and #lr_path:trim() > 0 then
            lua_path = lr_path:trim() .. ";" .. (lua_path or ";")
        end
        local lr_cpath = try { function ()
            return os.iorunv("luarocks", {"--lua-version=5.1", "path", "--lr-cpath"})
        end }
        if lr_cpath and #lr_cpath:trim() > 0 then
            cpath = cpath .. ";" .. lr_cpath:trim()
        end
        local logdir = lunet_new_logdir(os)
        local logfile = path.join(logdir, "busted.txt")
        if is_host("windows") then
            os.execv("cmd", {"/C", "set LUA_CPATH=" .. cpath .. "&& " ..
                             luajit .. " " .. busted_entry .. " spec/"})
        else
            -- pipefail keeps busted's own nonzero exit (failures/errors)
            -- visible through the tee capture.
            local prefix = "LUA_CPATH=" .. lunet_quote(cpath) .. " "
            if lua_path then
                prefix = prefix .. "LUA_PATH=" .. lunet_quote(lua_path) .. " "
            end
            os.execv("bash", {"-lc", "set -o pipefail; " .. prefix ..
                              lunet_quote(luajit) .. " " .. lunet_quote(busted_entry) ..
                              " spec/ 2>&1 | tee " .. lunet_quote(logfile)})
        end
        -- Anti-regression guard: pending tests report green and let 93 tests
        -- rot silently for ~6 months. Fail on ANY pending count unless
        -- LUNET_ALLOW_PENDING=1 is set. (Unix only: the windows cmd path
        -- does not capture output, so the guard cannot parse a summary.)
        local output = os.isfile(logfile) and io.readfile(logfile) or ""
        local pending = tonumber(output:match("(%d+)%s+pending")) or 0
        if pending > 0 and os.getenv("LUNET_ALLOW_PENDING") ~= "1" then
            local summary = output:match("[^\r\n]*pending[^\r\n]*") or ""
            raise("busted reported " .. pending .. " pending test(s) -- pending tests are forbidden (set LUNET_ALLOW_PENDING=1 to override): " .. summary)
        end
    end)
task_end()

task("check-types")
    set_menu {
        usage = "xmake check-types",
        description = "Validate LuaCATS annotations with lua-language-server"
    }
    on_run(function ()
        import("core.base.json")
        local luals = "lua-language-server"
        local ok = os.execv(luals, {"--version"}, {try = true})
        assert(ok == 0, "lua-language-server not found on PATH. Install via contributing/deps/ (macOS: brew install lua-language-server, Debian: contributing/deps/debian.sh)")
        local ts = os.date("%Y%m%d_%H%M%S")
        local logdir = path.join(os.projectdir(), ".tmp", "logs", ts .. "-check-types")
        os.mkdir(logdir)
        local outfile = path.join(logdir, "check.json")
        -- LuaLS generates its built-in meta definitions (string, number, table,
        -- ...) into --metapath on first run, which defaults to a directory
        -- inside the install tree. A system-wide install is root-owned, so a
        -- non-root runner cannot write there: LuaLS logs the EACCES, carries on
        -- without any builtins loaded and reports every stdlib type as
        -- `Undefined type or alias`. Keep the cache project-local and writable.
        local metadir = path.join(os.projectdir(), ".tmp", "luals-meta")
        os.mkdir(metadir)
        -- LuaLS 3.x always exits 0 for --check; the gate parses the JSON report
        -- instead. Diagnostics are filtered to the checklevel (Warning = severity
        -- 1..2), so any entry in the report is a gate failure.
        os.execv(luals, {
            "--check", path.join(os.projectdir(), "types"),
            "--checklevel", "Warning",
            "--check_format", "json",
            "--check_out_path", outfile,
            "--configpath", path.join(os.projectdir(), ".luarc.json"),
            "--logpath", logdir,
            "--metapath", metadir,
        }, {try = true})
        assert(os.isfile(outfile), "lua-language-server wrote no report to " .. outfile)
        local report = json.loadfile(outfile)
        local problems = 0
        for uri, diags in pairs(report) do
            local file = uri:gsub("^file://", "")
            for _, d in ipairs(diags) do
                problems = problems + 1
                local line = (d.range and d.range.start and d.range.start.line or 0) + 1
                local sev = d.severity == 1 and "Error" or "Warning"
                cprint("${red}%s${clear}:%d: [%s] %s ${bright}(%s)${clear}", file, line, sev, tostring(d.message), tostring(d.code))
            end
        end
        if problems > 0 then
            raise(("check-types: %d problem(s) in types/ — full report: %s"):format(problems, outfile))
        end
        cprint("${green}check-types: types/ clean (0 problems)${clear} — report: " .. outfile)
    end)
task_end()

task("build-release")
    set_menu {
        usage = "xmake build-release",
        description = "Configure and build release profile (including SDK targets)"
    }
    on_run(function ()
        os.exec("xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y")
        os.exec("xmake build")
        -- SDK targets are set_default(false); build them explicitly so the
        -- local release gate covers what CI packages.
        os.exec("xmake build lunet-static")
        os.exec("xmake build sdk-api-test")
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
        if is_host("windows") then
            lunet_exec_logged(os, logdir, "04_build_lunet_mysql", "xmake build lunet-mysql || exit /b 0")
            lunet_exec_logged(os, logdir, "05_build_lunet_postgres", "xmake build lunet-postgres || exit /b 0")
        else
            lunet_exec_logged(os, logdir, "04_build_lunet_mysql", "xmake build lunet-mysql || true")
            lunet_exec_logged(os, logdir, "05_build_lunet_postgres", "xmake build lunet-postgres || true")
        end

        local runner = lunet_runner_path("debug")
        local runnerq = lunet_quote(runner)
        -- DB stress: detect_leaks=0 because libmysqlclient C++ runtime has
        -- known fixed-overhead allocations.
        -- LSAN regression: detect_leaks=1 with exitcode=23 so the caller
        -- can parse the summary and assert <= 4 allocations (known overhead).
        if is_host("windows") then
            lunet_exec_logged(os, logdir, "06_ci_easy_memory_db_stress",
                "set ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 && set LIGHT_DB_STRESS_OPS=" .. ops .. " && " .. runnerq .. " test/ci_easy_memory_db_stress.lua")
            lunet_exec_logged(os, logdir, "07_ci_easy_memory_lsan_regression",
                "set ASAN_OPTIONS=halt_on_error=1 && set LSAN_OPTIONS=exitcode=23 && " .. runnerq .. " test/ci_easy_memory_lsan_regression.lua")
        else
            lunet_exec_logged(os, logdir, "06_ci_easy_memory_db_stress",
                "ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 LIGHT_DB_STRESS_OPS=" .. ops .. " timeout 120 " .. runnerq .. " test/ci_easy_memory_db_stress.lua")
            lunet_exec_logged(os, logdir, "07_ci_easy_memory_lsan_regression",
                "ASAN_OPTIONS=halt_on_error=1 LSAN_OPTIONS=exitcode=23 timeout 120 " .. runnerq .. " test/ci_easy_memory_lsan_regression.lua || true")
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
        os.mkdir(path.join(os.projectdir(), ".tmp"))
        local workers = os.getenv("STRESS_WORKERS") or "50"
        local ops = os.getenv("STRESS_OPS") or "100"
        os.exec("xmake build-debug")
        local runner = lunet_runner_path("debug")
        os.execv(runner, {"test/stress_test.lua"}, {envs = {STRESS_WORKERS = workers, STRESS_OPS = ops}})
        -- Accept/UDP concurrency regressions: parked-acceptor wakeup on close,
        -- and accept+UDP heartbeat concurrency.
        os.execv(runner, {"test/socket_close_wakeup.lua"})
        os.execv(runner, {"test/accept_udp_concurrent.lua"})
        -- accept() must reject a connected client handle passed where a
        -- listener is expected: fail immediately instead of reading server-arm
        -- fields through the client arm's read_ref/write_ref union overlay,
        -- which would park the coroutine forever and corrupt client state.
        os.execv(runner, {"test/socket_accept_type_check.lua"})
        -- listen_cb error-path fault injection. Requires LUNET_TEST_FAULTS
        -- (debug/trace profile only); each mode below exercises a distinct
        -- branch in lunet_socket_test_fault_take.
        os.execv(runner, {"test/socket_listen_error_paths.lua"},
            {envs = {LUNET_TEST_SOCKET_LISTEN_FAULT = "nonthread_waiter"}})
        os.execv(runner, {"test/socket_listen_error_paths.lua"},
            {envs = {LUNET_TEST_SOCKET_LISTEN_FAULT = "queue_fail"}})
        os.execv(runner, {"test/socket_listen_error_paths.lua"},
            {envs = {LUNET_TEST_SOCKET_LISTEN_FAULT = "alloc_fail+drop_fail"}})
        -- Listener handle must not dangle after the catastrophic self-close
        -- path. Lua has no os.setenv, so the fault mode that drives
        -- lunet_listen_cb into self-close must be supplied here.
        os.execv(runner, {"test/socket_listener_self_close.lua"},
            {envs = {LUNET_TEST_SOCKET_LISTEN_FAULT = "alloc_fail,drop_fail"}})
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

        local mysql_modules = os.files("build/**/release/lunet/mysql.*")
        if #mysql_modules > 0 then
            os.execv(runner, {"test/smoke_mysql.lua"})
        else
            print("[smoke] skip mysql: driver module not built")
        end

        local postgres_modules = os.files("build/**/release/lunet/postgres.*")
        if #postgres_modules > 0 then
            os.execv(runner, {"test/smoke_postgres.lua"})
        else
            print("[smoke] skip postgres: driver module not built")
        end
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
        description = "Run the socket stress repro with LuaJIT+Lunet ASan (macOS)"
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

task("examples-compile")
    set_menu {
        usage = "xmake examples-compile",
        description = "Run examples compile/syntax check"
    }
    on_run(function ()
        os.exec("xmake build-release")
        local runner = lunet_runner_path("release")
        os.execv(runner, {"test/ci_examples_compile.lua"})
    end)
task_end()

task("sqlite3-smoke")
    set_menu {
        usage = "xmake sqlite3-smoke",
        description = "Build and run SQLite3 example smoke test"
    }
    on_run(function ()
        os.exec("xmake build-release")
        os.exec("xmake build lunet-sqlite3")
        local runner = lunet_runner_path("release")
        os.execv(runner, {"examples/03_db_sqlite3.lua"})
    end)
task_end()

task("ci")
    set_menu {
        usage = "xmake ci",
        description = "Run local CI parity sequence (lint, check-types, build, examples, sqlite3 smoke)"
    }
    on_run(function ()
        os.exec("xmake lint")
        os.exec("xmake check-types")
        os.exec("xmake build-release")
        os.exec("xmake build lunet-sqlite3")

        local runner = lunet_runner_path("release")
        print("--- examples compile check ---")
        os.execv(runner, {"test/ci_examples_compile.lua"})
        print("--- sqlite3 example smoke ---")
        os.execv(runner, {"examples/03_db_sqlite3.lua"})
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

-- Full CI-parity gate in a clean Debian trixie (arm64) container.
-- Runs: cargo test, xmake ci, xmake test, lnt_shared smoke,
-- preflight-easy-memory (ASAN+EasyMem+LSAN).  Requires Docker (colima).
-- Classic builder only (no BuildKit), no volume mounts.
task("gate-trixie")
    set_menu {
        usage = "xmake gate-trixie",
        description = "Run all local CI-parity gates in Docker (Debian trixie, arm64)"
    }
    on_run(function ()
        local envs = {DOCKER_BUILDKIT = "0"}
        os.execv("docker", {"build", "-f", "docker/Dockerfile", "-t", "lunet-gate:trixie", "."}, {envs = envs})
        os.execv("docker", {"run", "--rm", "--platform", "linux/arm64", "lunet-gate:trixie"}, {envs = envs})
    end)
task_end()

-- =============================================================================
-- lnt_shared extension (Rust, optional)
-- =============================================================================
-- Build:   xmake build-lnt-shared
-- Smoke:   xmake lnt-shared-smoke
-- The extension lives entirely in ext/lnt_shared/ and is loaded at runtime
-- by the Lua module lunet.lnt_shared via LuaJIT FFI.  It does not need to be
-- linked into lunet-run.

task("build-lnt-shared")
    set_menu {
        usage = "xmake build-lnt-shared",
        description = "Build the lnt_shared Rust extension (ext/lnt_shared)"
    }
    on_run(function ()
        local crate_dir = path.join(os.scriptdir(), "ext", "lnt_shared")
        print("[lnt_shared] cargo build --release ...")
        os.execv("cargo", {"build", "--release"}, {curdir = crate_dir})
        print("[lnt_shared] built: " .. path.join(crate_dir, "target", "release"))
    end)
task_end()

task("lnt-shared-smoke")
    set_menu {
        usage = "xmake lnt-shared-smoke",
        description = "Build lnt_shared then run the smoke test"
    }
    on_run(function ()
        os.exec("xmake build-lnt-shared")
        os.exec("xmake build-release")
        local runner = lunet_runner_path("release")
        os.execv(runner, {"test/smoke_lnt_shared.lua"})
    end)
task_end()

task("build-ngx-shared")
    set_menu {
        usage = "xmake build-ngx-shared",
        description = "Deprecated alias for xmake build-lnt-shared"
    }
    on_run(function ()
        os.exec("xmake build-lnt-shared")
    end)
task_end()

task("ngx-shared-smoke")
    set_menu {
        usage = "xmake ngx-shared-smoke",
        description = "Deprecated alias for xmake lnt-shared-smoke"
    }
    on_run(function ()
        os.exec("xmake lnt-shared-smoke")
    end)
task_end()

-- =============================================================================
-- jsonic extension (Rust, optional) - dkjson-style JSON decode via FFI
-- =============================================================================
-- Build:   xmake build-jsonic
-- Smoke:   xmake jsonic-smoke
-- Wraps https://github.com/g1mv/jsonic (MIT/Apache-2.0, zero deps). Lives
-- entirely in ext/jsonic/ and is loaded at runtime by lunet.jsonic via
-- LuaJIT FFI. Does not need to be linked into lunet-run.

task("build-jsonic")
    set_menu {
        usage = "xmake build-jsonic",
        description = "Build the jsonic Rust extension (ext/jsonic)"
    }
    on_run(function ()
        local crate_dir = path.join(os.scriptdir(), "ext", "jsonic")
        print("[jsonic] cargo build --release ...")
        os.execv("cargo", {"build", "--release"}, {curdir = crate_dir})
        print("[jsonic] built: " .. path.join(crate_dir, "target", "release"))
    end)
task_end()

task("jsonic-smoke")
    set_menu {
        usage = "xmake jsonic-smoke",
        description = "Build jsonic then run the smoke test"
    }
    on_run(function ()
        os.exec("xmake build-jsonic")
        os.exec("xmake build-release")
        local runner = lunet_runner_path("release")
        os.execv(runner, {"test/smoke_jsonic.lua"})
    end)
task_end()

-- =============================================================================
-- paxe extension (Rust, optional) - PAXE datagram encryption via LuaJIT FFI
-- =============================================================================
-- Build:   xmake build-paxe
-- Zero-dependency cdylib living in ext/paxe/, loaded at runtime by
-- lunet.paxe via LuaJIT FFI. Not linked into lunet-run. The toolchain is
-- pinned by ext/paxe/rust-toolchain.toml, so cargo must run with the crate
-- dir as cwd (rustup resolves the pin from cwd, not --manifest-path).
-- NOTE: the legacy C-based "lunet-paxe" target above is deliberately left
-- broken (it lists the deleted src/paxe.c); item10 removes it. Do not
-- "repair" it here.

task("build-paxe")
    set_menu {
        usage = "xmake build-paxe",
        description = "Build the paxe Rust extension (ext/paxe)"
    }
    on_run(function ()
        local crate_dir = path.join(os.scriptdir(), "ext", "paxe")
        print("[paxe] cargo build --release ...")
        os.execv("cargo", {"build", "--release"}, {curdir = crate_dir})
        print("[paxe] built: " .. path.join(crate_dir, "target", "release"))
    end)
task_end()
