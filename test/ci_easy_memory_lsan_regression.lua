-- Regression probe for EasyMem+ASAN leak cleanup on Linux.
-- This script intentionally loads DB driver modules and performs
-- minimal work so LeakSanitizer can validate shutdown behavior.

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

local function mysql_optional_probe()
    local ok, db = pcall(require, "lunet.mysql")
    if not ok then
        info("skip lunet.mysql (module unavailable): " .. tostring(db))
        return
    end

    -- Even when the server is unavailable, this exercises async connect setup.
    local conn, err = db.open({
        host = "127.0.0.1",
        port = 3306,
        user = "root",
        password = "root",
        database = "test"
    })

    if conn then
        db.close(conn)
        info("mysql probe connected and closed")
        return
    end

    info("mysql probe server unavailable: " .. tostring(err))
end

lunet.spawn(function()
    sqlite_probe()
    mysql_optional_probe()

    if failures > 0 then
        info("probe completed with failures=" .. failures)
        _G.__lunet_exit_code = 1
    else
        info("probe completed successfully")
        _G.__lunet_exit_code = 0
    end
end)
