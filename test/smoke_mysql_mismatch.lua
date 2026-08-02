-- Smoke test for the MySQL parameter count mismatch guard (item18)
-- Run: ./build/lunet test/smoke_mysql_mismatch.lua
-- Requires: MySQL/MariaDB running on localhost:3306
-- Env overrides: LUNET_MYSQL_HOST/PORT/USER/PASSWORD/DATABASE
-- Strictness: LUNET_DB_REQUIRED=1 makes an unreachable server a hard failure
--
-- The driver compares mysql_stmt_param_count() against the number of
-- parameters collected from Lua and refuses to execute on disagreement.
-- That guard is both a caller-error check and a tripwire for Lua-C stack
-- pollution (see AGENTS.md: a thread left on the stack by
-- lunet_ensure_coroutine once made collect_params miscount, and this guard
-- was the symptom reporter). Each mismatch must return no result plus a
-- non-empty error string; we assert on the type/emptiness of the error, not
-- its exact text, so the test is not a transcription of the format string.

local lunet = require("lunet")
local db = require("lunet.mysql")

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*)[/\\]") or "."
local gate = dofile(script_dir .. "/db_smoke_gate.lua")

local cfg = gate.config("MYSQL", {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "root",
    database = "test"
})

local failures = 0

local function fail(label, detail)
    failures = failures + 1
    print("FAIL: " .. label .. (detail and (": " .. tostring(detail)) or ""))
end

local function pass(label)
    print("   OK: " .. label)
end

-- The documented failure contract: no result, plus a non-empty error string.
local function expect_mismatch(label, res, err)
    if res ~= nil then
        fail(label, "expected no result on mismatch, got " .. type(res))
        return
    end
    if type(err) ~= "string" or #err == 0 then
        fail(label, "expected a non-empty error string, got " .. type(err))
        return
    end
    pass(label)
end

local function main()
    print("=== MySQL Parameter Count Mismatch Guard Test (item18) ===")

    print("0. Opening connection...")
    local conn, err = db.open(cfg)
    if not conn then
        gate.open_failed("MySQL", cfg, err)
        return
    end
    pass("Connection opened")

    -- Scratch table for the exec_params positive/usability checks.
    local _
    _, err = db.exec(conn,
        "CREATE TABLE IF NOT EXISTS item18_mismatch (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))")
    if err then
        fail("setup: create table", err)
        db.close(conn)
        __lunet_exit_code = 1
        return
    end

    -- 1. Too FEW params for the placeholders present. Without the guard,
    --    MySQL would execute with the unbound placeholder treated as
    --    unset/NULL -- a silent wrong answer.
    print("1. Too few params (1 given, 2 placeholders)...")
    expect_mismatch("query_params too few",
        db.query_params(conn, "SELECT ? AS a, ? AS b", "x"))
    expect_mismatch("exec_params too few",
        db.exec_params(conn, "SELECT ? AS a, ? AS b", "x"))

    -- 2. Connection remains usable IMMEDIATELY after a single mismatch.
    print("2. Connection usable immediately after mismatch...")
    local rows
    rows, err = db.query_params(conn, "SELECT ? AS got", "usable")
    if err or not rows or #rows ~= 1 or rows[1].got ~= "usable" then
        fail("query_params usable after mismatch", err or "unexpected rows")
    else
        pass("query_params usable after mismatch")
    end
    local res
    res, err = db.exec_params(conn, "INSERT INTO item18_mismatch (name) VALUES (?)", "after_mismatch")
    if err or not res then
        fail("exec_params usable after mismatch", err)
    else
        pass("exec_params usable after mismatch")
    end

    -- 3. Too MANY params for the placeholders.
    print("3. Too many params (2 given, 1 placeholder)...")
    expect_mismatch("query_params too many",
        db.query_params(conn, "SELECT ? AS a", "x", "y"))
    expect_mismatch("exec_params too many",
        db.exec_params(conn, "SELECT ? AS a", "x", "y"))

    -- 4. ZERO params passed to a statement that HAS placeholders.
    print("4. Zero params against 1 placeholder...")
    expect_mismatch("query_params zero vs placeholders",
        db.query_params(conn, "SELECT ? AS a"))
    expect_mismatch("exec_params zero vs placeholders",
        db.exec_params(conn, "SELECT ? AS a"))

    -- 5. Params passed to a statement that has NO placeholders.
    print("5. Params against no placeholders...")
    expect_mismatch("query_params params vs none",
        db.query_params(conn, "SELECT 1", "x"))
    expect_mismatch("exec_params params vs none",
        db.exec_params(conn, "SELECT 1", "x"))

    -- 6. POSITIVE CONTROL: no placeholders and no params SUCCEEDS. A guard
    --    that rejected everything would pass a suite of only-negative cases.
    print("6. Positive control (no placeholders, no params)...")
    rows, err = db.query_params(conn, "SELECT 1 AS one")
    if err or not rows or #rows ~= 1 or tostring(rows[1].one) ~= "1" then
        fail("query_params positive control", err or "unexpected rows")
    else
        pass("query_params positive control")
    end
    res, err = db.exec_params(conn, "INSERT INTO item18_mismatch (name) VALUES ('pos_control')")
    if err or not res then
        fail("exec_params positive control", err)
    else
        pass("exec_params positive control")
    end

    -- 7. REPEATED-mismatch loop: the leak/teardown check. Each round trips
    --    to the server; if the failure path leaked statement handles or
    --    failed to unlock the mutex, the connection stalls or the server
    --    runs out of statement handles. NOTE: this loop is bounded by the
    --    external timeout wrapper -- a timeout here indicates a mutex leak
    --    or stall on the failure path, NOT a slow server.
    print("7. Repeated-mismatch loop (300 iterations)...")
    local loop_bad = 0
    for _ = 1, 300 do
        local r, e = db.query_params(conn, "SELECT ? AS a, ? AS b", "x")
        if r ~= nil or type(e) ~= "string" or #e == 0 then
            loop_bad = loop_bad + 1
        end
    end
    if loop_bad > 0 then
        fail("repeated-mismatch loop", loop_bad .. " of 300 iterations returned the wrong shape")
    else
        pass("300 mismatches all returned no result + non-empty error string")
    end
    rows, err = db.query_params(conn, "SELECT ? AS got", "post_loop")
    if err or not rows or #rows ~= 1 or rows[1].got ~= "post_loop" then
        fail("well-formed query after repeated mismatches", err or "unexpected rows")
    else
        pass("well-formed query_params succeeds after 300 mismatches (no leak/stall)")
    end
    res, err = db.exec_params(conn, "INSERT INTO item18_mismatch (name) VALUES (?)", "post_loop")
    if err or not res then
        fail("well-formed exec_params after repeated mismatches", err)
    else
        pass("well-formed exec_params succeeds after 300 mismatches (no leak/stall)")
    end

    -- 8. Coroutine-entry case: the original defect was specific to coroutine
    --    handling (a thread left on the Lua stack was counted as a param),
    --    so a main-coroutine-only test misses a recurrence. A freshly
    --    spawned coroutine issues both an intentional mismatch (guard must
    --    fire) and a well-formed param query (guard must NOT fire -- a
    --    spurious mismatch here is the stack-pollution regression).
    print("8. Mismatch and well-formed query from a spawned coroutine...")
    local co_done = false
    local co_failures = 0
    lunet.spawn(function()
        local r, e = db.query_params(conn, "SELECT ? AS a", "x", "y")
        if r ~= nil or type(e) ~= "string" or #e == 0 then
            co_failures = co_failures + 1
            fail("coroutine-entry query_params mismatch", e or "wrong shape")
        end
        r, e = db.exec_params(conn, "SELECT ? AS a", "x", "y")
        if r ~= nil or type(e) ~= "string" or #e == 0 then
            co_failures = co_failures + 1
            fail("coroutine-entry exec_params mismatch", e or "wrong shape")
        end
        local wrows, werr = db.query_params(conn, "SELECT ? AS got", "from_coroutine")
        if werr or not wrows or #wrows ~= 1 or wrows[1].got ~= "from_coroutine" then
            co_failures = co_failures + 1
            fail("coroutine-entry well-formed query_params (stack-hygiene tripwire)", werr or "unexpected rows")
        end
        co_done = true
    end)
    local waited_ms = 0
    while not co_done and waited_ms < 15000 do
        lunet.sleep(10)
        waited_ms = waited_ms + 10
    end
    if not co_done then
        fail("coroutine-entry case", "spawned coroutine did not finish within 15s")
    elseif co_failures == 0 then
        pass("spawned coroutine: mismatch rejected, well-formed query counted correctly")
    end

    -- 9. Teardown.
    print("9. Cleaning up...")
    db.exec(conn, "DROP TABLE item18_mismatch")
    db.close(conn)
    pass("Table dropped, connection closed")

    print("")
    if failures == 0 then
        print("=== All MySQL mismatch guard tests passed ===")
        __lunet_exit_code = 0
    else
        print("=== " .. failures .. " mismatch guard test(s) FAILED ===")
        __lunet_exit_code = 1
    end
end

lunet.spawn(main)
