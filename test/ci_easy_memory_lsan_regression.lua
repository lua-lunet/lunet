-- Regression probe for EasyMem+ASAN leak cleanup on Linux.
-- This script exercises all driver modules including MySQL, stresses them
-- over multiple cycles, and exits cleanly so LeakSanitizer can validate
-- shutdown behavior.
--
-- libmysqlclient is a C++ library with a known fixed overhead of ~4
-- allocations (~153 bytes) from one-time C++ runtime initialization
-- (locale facets, thread-local storage).  These do NOT grow with usage.
-- The CI wrapper uses LSAN_OPTIONS=exitcode=23 to distinguish leak-exit
-- from crash-exit and asserts the allocation count stays within the known
-- threshold.

local lunet = require("lunet")

local ITERATIONS = tonumber(os.getenv("LSAN_STRESS_ITERATIONS")) or 5
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

    for i = 1, ITERATIONS do
        local conn, err = db.open({ path = ":memory:" })
        if not conn then
            fail("sqlite open failed (iter " .. i .. "): " .. tostring(err))
            return
        end

        local _, exec_err = db.exec(conn, "CREATE TABLE lsan_probe (id INTEGER PRIMARY KEY)")
        if exec_err then
            fail("sqlite exec failed (iter " .. i .. "): " .. tostring(exec_err))
        end

        db.close(conn)
    end
    info("sqlite probe completed (" .. ITERATIONS .. " iterations)")
end

local function mysql_probe()
    local ok, db = pcall(require, "lunet.mysql")
    if not ok then
        info("skip lunet.mysql (module unavailable): " .. tostring(db))
        return
    end

    -- Stress multiple connect/close cycles to prove leaks do not grow.
    -- Server is typically unavailable in CI, so connect fails — that still
    -- exercises the full init/thread_init/close/thread_end/library_end path.
    for i = 1, ITERATIONS do
        local conn, err = db.open({
            host = "127.0.0.1",
            port = 3306,
            user = "root",
            password = "root",
            database = "test"
        })

        if conn then
            db.close(conn)
        end
    end
    info("mysql probe completed (" .. ITERATIONS .. " iterations)")
end

lunet.spawn(function()
    sqlite_probe()
    mysql_probe()

    if failures > 0 then
        info("probe completed with failures=" .. failures)
        _G.__lunet_exit_code = 1
    else
        info("probe completed successfully")
        _G.__lunet_exit_code = 0
    end
end)
