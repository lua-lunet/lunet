-- Concurrency smoke test for the MySQL driver (item19b)
-- Run: ./build/lunet test/smoke_mysql_concurrency.lua
-- Requires: MySQL/MariaDB running on localhost:3306
-- Env overrides: LUNET_MYSQL_HOST/PORT/USER/PASSWORD/DATABASE
-- Strictness: LUNET_DB_REQUIRED=1 makes an unreachable server a hard failure
--
-- Several coroutines issue parameterised queries against ONE connection
-- concurrently. The driver runs every query on the libuv thread pool and
-- serialises each connection with a uv_mutex_t that db_query_work_cb must
-- unlock on every one of its many exit paths; a missed unlock is a
-- permanent deadlock and is invisible to the sequential smoke tests
-- (test/smoke_mysql.lua never contends the mutex).
--
-- CRITICAL DESIGN PROPERTY: every coroutine's query carries a UNIQUE
-- parameter and its correct result is a pure function of that value; each
-- coroutine asserts it received ITS OWN answer. A batch of identical
-- queries cannot detect results crossing between concurrent queries -
-- with identical queries the wrong answer looks like the right one.
--
-- Deliberate parameter-count-mismatch failures are interleaved with the
-- successes in the same batch, because the error paths are where unlock
-- bugs live: they are the early returns least likely to have been run.
-- Both query_params and exec_params are represented; they are separate
-- entry points sharing the same connection, mutex and work callback.
--
-- TIMEOUT INTERPRETATION: the batch wait below is bounded. A timeout here
-- means a lost mutex unlock (permanent deadlock on the connection), NOT a
-- slow server - the workload is a handful of trivial queries against a
-- local database and completes in milliseconds when the locking is right.

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
local function fail(msg)
    failures = failures + 1
    print("FAIL: " .. msg)
end
local function pass(msg)
    print("   OK: " .. msg)
end

local N_CO = 6 -- coroutine count: contention, not load
local BATCH_DEADLINE_MS = 30000

-- The correct answer for coroutine i is a pure function of i, so a result
-- crossed over from coroutine j carries j's values and fails the asserts.
local function expected_sig(i)
    return i * 2 + 1
end

-- Assert the deliberate-failure contract: no result, plus the specific
-- parameter-count-mismatch guard error (so we know the INTENDED early
-- return fired, not some unrelated error).
local function expect_mismatch(label, res, err)
    if res ~= nil then
        fail(label .. ": expected no result on mismatch, got " .. type(res))
        return false
    end
    if type(err) ~= "string"
        or err:find("parameter count mismatch", 1, true) == nil then
        fail(label .. ": expected parameter count mismatch, got err=" .. tostring(err))
        return false
    end
    return true
end

-- One coroutine's interleaved batch: success, failure, success, failure,
-- success - alternating query_params and exec_params.
local function coroutine_batch(conn, i)
    -- 1. Successful query_params whose answer is unique to this coroutine.
    local rows, err = db.query_params(conn, "SELECT ? AS tag, ? * 2 + 1 AS sig", i, i)
    if err or not rows or #rows ~= 1
        or tonumber(rows[1].tag) ~= i
        or tonumber(rows[1].sig) ~= expected_sig(i) then
        fail("co " .. i .. " unique query_params: expected tag=" .. i
            .. " sig=" .. expected_sig(i) .. ", got err=" .. tostring(err)
            .. " tag=" .. tostring(rows and rows[1] and rows[1].tag)
            .. " sig=" .. tostring(rows and rows[1] and rows[1].sig))
        return
    end

    -- 2. Deliberate failure via query_params (one param short).
    expect_mismatch("co " .. i .. " query_params mismatch",
        db.query_params(conn, "SELECT ? AS a, ? AS b", i))

    -- 3. Successful exec_params carrying the same unique values.
    local res
    res, err = db.exec_params(conn,
        "INSERT INTO item19b_conc (tag, sig) VALUES (?, ?)", i, expected_sig(i))
    if err or not res or res.affected_rows ~= 1
        or type(res.last_insert_id) ~= "number" then
        fail("co " .. i .. " unique exec_params insert: " .. tostring(err))
        return
    end
    local own_id = res.last_insert_id

    -- 4. Deliberate failure via exec_params (one param short).
    expect_mismatch("co " .. i .. " exec_params mismatch",
        db.exec_params(conn, "INSERT INTO item19b_conc (tag, sig) VALUES (?, ?)", i))

    -- 5. Read back THIS coroutine's own row by its own insert id: the
    --    definitive own-answer check across the thread-pool boundary.
    rows, err = db.query_params(conn,
        "SELECT tag, sig FROM item19b_conc WHERE id = ?", own_id)
    if err or not rows or #rows ~= 1
        or tonumber(rows[1].tag) ~= i
        or tonumber(rows[1].sig) ~= expected_sig(i) then
        fail("co " .. i .. " read-back of own row id=" .. own_id
            .. ": expected tag=" .. i .. " sig=" .. expected_sig(i)
            .. ", got err=" .. tostring(err)
            .. " tag=" .. tostring(rows and rows[1] and rows[1].tag)
            .. " sig=" .. tostring(rows and rows[1] and rows[1].sig))
        return
    end
end

local function main()
    print("=== MySQL Concurrency Test (item19b) ===")

    print("0. Opening connection...")
    local conn, err = db.open(cfg)
    if not conn then
        gate.open_failed("MySQL", cfg, err)
        return
    end
    pass("Connection opened")

    -- Fresh scratch table every run so repeat runs are idempotent even if a
    -- previous run died before cleanup.
    print("1. Creating scratch table...")
    local _
    _, err = db.exec(conn, "DROP TABLE IF EXISTS item19b_conc")
    if err then
        fail("setup: drop table: " .. tostring(err))
        db.close(conn)
        __lunet_exit_code = 1
        return
    end
    _, err = db.exec(conn, "CREATE TABLE item19b_conc ("
        .. "id INT AUTO_INCREMENT PRIMARY KEY, tag INT NOT NULL, sig BIGINT NOT NULL)")
    if err then
        fail("setup: create table: " .. tostring(err))
        db.close(conn)
        __lunet_exit_code = 1
        return
    end
    pass("Scratch table created")

    -- 2. The concurrent batch. All coroutines spawn before any is awaited;
    --    each yields into the libuv thread pool on its first query, so the
    --    pool runs several work items at once and the connection mutex is
    --    genuinely contended.
    print("2. Launching " .. N_CO .. " coroutines x 5 ops "
        .. "(3 unique successes + 2 deliberate failures each)...")
    local completed = 0
    for i = 1, N_CO do
        lunet.spawn(function()
            local ok, perr = pcall(coroutine_batch, conn, i)
            if not ok then
                fail("co " .. i .. " raised: " .. tostring(perr))
            end
            completed = completed + 1
        end)
    end

    -- Bounded wait. See the header: a timeout here is a LOST MUTEX UNLOCK
    -- (permanent deadlock), not a slow server.
    local waited = 0
    while completed < N_CO and waited < BATCH_DEADLINE_MS do
        lunet.sleep(10)
        waited = waited + 10
    end
    if completed < N_CO then
        fail("concurrent batch: only " .. completed .. " of " .. N_CO
            .. " coroutines finished within " .. (BATCH_DEADLINE_MS / 1000)
            .. "s - timeout means a lost mutex unlock (deadlock), NOT a slow server")
        db.close(conn)
        __lunet_exit_code = 1
        return
    end
    if failures == 0 then
        pass("all " .. N_CO .. " coroutines got their own answers; "
            .. (N_CO * 2) .. " deliberate mismatches rejected")
    end

    -- 3. Post-batch usability: the connection must still answer after the
    --    contended batch (and after its error paths) - proof no exit path
    --    left the mutex locked or the connection corrupted.
    print("3. Connection usable after the batch...")
    local rows
    rows, err = db.query_params(conn, "SELECT ? AS got", "post_batch")
    if err or not rows or #rows ~= 1 or rows[1].got ~= "post_batch" then
        fail("query_params after batch: " .. tostring(err))
    else
        pass("query_params succeeds after the batch")
    end
    rows, err = db.query(conn, "SELECT COUNT(*) AS n FROM item19b_conc")
    if err or not rows or #rows ~= 1 or tonumber(rows[1].n) ~= N_CO then
        fail("row count after batch: expected " .. N_CO .. ", got err="
            .. tostring(err) .. " n=" .. tostring(rows and rows[1] and rows[1].n))
    else
        pass("all " .. N_CO .. " unique inserts landed exactly once")
    end

    -- 4. Teardown.
    print("4. Cleaning up...")
    db.exec(conn, "DROP TABLE item19b_conc")
    db.close(conn)
    pass("Table dropped, connection closed")

    print("")
    if failures == 0 then
        print("=== All MySQL concurrency tests passed ===")
        __lunet_exit_code = 0
    else
        print("=== " .. failures .. " concurrency test failure(s) ===")
        __lunet_exit_code = 1
    end
end

lunet.spawn(main)
