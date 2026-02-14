-- Lightweight DB stress for EasyMem+ASAN CI profiles.
-- Designed to run fast and pass in environments without MySQL/Postgres servers.

local lunet = require("lunet")

local OPS = tonumber(os.getenv("LIGHT_DB_STRESS_OPS")) or 20
local failures = 0
local skips = 0

local function log(msg)
    print("[EASYMEM_CI] " .. msg)
end

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[EASYMEM_CI][FAIL] " .. msg .. "\n")
end

local function sqlite_stress()
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

    local _, create_err = db.exec(conn, [[
        CREATE TABLE ci_easy_mem_stress (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            v INTEGER NOT NULL
        )
    ]])
    if create_err then
        fail("sqlite create table failed: " .. tostring(create_err))
        db.close(conn)
        return
    end

    for i = 1, OPS do
        local _, ins_err = db.exec_params(
            conn,
            "INSERT INTO ci_easy_mem_stress (name, v) VALUES (?, ?)",
            "row_" .. i,
            i
        )
        if ins_err then
            fail("sqlite insert failed at op " .. i .. ": " .. tostring(ins_err))
            break
        end

        local rows, q_err = db.query_params(
            conn,
            "SELECT COUNT(*) AS c FROM ci_easy_mem_stress WHERE v <= ?",
            i
        )
        if q_err or not rows or not rows[1] or tonumber(rows[1].c or 0) ~= i then
            fail("sqlite count query failed at op " .. i .. ": " .. tostring(q_err))
            break
        end
    end

    db.close(conn)
    log("sqlite stress completed (" .. OPS .. " ops)")
end

local function optional_driver_probe(module_name, open_args)
    local ok, db = pcall(require, module_name)
    if not ok then
        skips = skips + 1
        log("skip " .. module_name .. " (module unavailable): " .. tostring(db))
        return
    end

    local conn, err = db.open(open_args)
    if not conn then
        skips = skips + 1
        log("skip " .. module_name .. " (server unavailable): " .. tostring(err))
        return
    end

    for i = 1, OPS do
        local rows, q_err = db.query(conn, "SELECT 1 AS ok")
        if q_err or not rows or not rows[1] then
            fail(module_name .. " query failed at op " .. i .. ": " .. tostring(q_err))
            break
        end
    end

    db.close(conn)
    log(module_name .. " probe completed (" .. OPS .. " ops)")
end

lunet.spawn(function()
    log("starting db stress profile (ops=" .. OPS .. ")")

    sqlite_stress()

    optional_driver_probe("lunet.mysql", {
        host = "127.0.0.1",
        port = 3306,
        user = "root",
        password = "root",
        database = "test"
    })

    optional_driver_probe("lunet.postgres", {
        host = "127.0.0.1",
        port = 5432,
        user = os.getenv("USER") or "postgres",
        password = "",
        database = "postgres"
    })

    if failures > 0 then
        log("completed with failures=" .. failures .. ", skips=" .. skips)
        _G.__lunet_exit_code = 1
    else
        log("completed successfully, skips=" .. skips)
        _G.__lunet_exit_code = 0
    end
end)
