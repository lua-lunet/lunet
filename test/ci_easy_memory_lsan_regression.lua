-- Regression probe for EasyMem+ASAN leak cleanup on Linux.
-- This script exercises lunet's own code paths (pure-C drivers only) and
-- exits cleanly so LeakSanitizer can validate that we free everything.
--
-- IMPORTANT: Do NOT load lunet.mysql here.  libmysqlclient is a C++ library
-- whose one-time runtime allocations (locale facets, etc.) are reported as
-- leaks by LSAN.  Because the library is dlopen'd, LSAN often cannot resolve
-- the module name (shows "<unknown module>") making suppressions unreliable.
-- MySQL driver coverage lives in ci_easy_memory_db_stress.lua instead.

local lunet = require("lunet")

local failures = 0

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[EASYMEM_LSAN][FAIL] " .. msg .. "\n")
end

local function info(msg)
    print("[EASYMEM_LSAN] " .. msg)
end

local function sqlite_probe()
    local ok, db = pcall(require, "lunet.sqlite3")
    if not ok then
        fail("could not require lunet.sqlite3: " .. tostring(db))
        return
    end

    local conn, err = db.open({ path = ":memory:" })
    if not conn then
        fail("sqlite open failed: " .. tostring(err))
        return
    end

    local _, exec_err = db.exec(conn, "CREATE TABLE lsan_probe (id INTEGER PRIMARY KEY)")
    if exec_err then
        fail("sqlite exec failed: " .. tostring(exec_err))
    end

    db.close(conn)
    info("sqlite probe completed")
end

lunet.spawn(function()
    sqlite_probe()

    if failures > 0 then
        info("probe completed with failures=" .. failures)
        _G.__lunet_exit_code = 1
    else
        info("probe completed successfully")
        _G.__lunet_exit_code = 0
    end
end)
