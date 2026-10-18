-- Smoke test for the lunet.sqlite3 prepared statements
--
-- Run after the driver build:
--   "$(find build -path '*/release/lunet-run' -type f | head -1)" test/smoke_sqlite3_prepare.lua
--
-- Covers: prepare → exec with params twice (values differ — the reset +
-- clear-bindings discipline is proven by the second run), query with
-- params, write rejection on the read-only handle at PREPARE time, the
-- busy error on a second concurrent call, loud use-after-close, and GC
-- safety (a dropped statement finalizes without crashing). Files live
-- under .tmp/ so a run never litters the repo root.

local lunet = require("lunet")
local db = require("lunet.sqlite3")

local failures = 0
local steps = 0

local function check(cond, msg)
    steps = steps + 1
    if cond then
        print(string.format("  ok   %s", msg))
    else
        failures = failures + 1
        print(string.format("  FAIL %s", msg))
    end
end

local DB_PATH = ".tmp/smoke_prepare.db"

os.execute("mkdir -p .tmp")
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")

lunet.spawn(function()
    local rw, ro = db.open({ path = DB_PATH, create = "WAL" })
    check(rw and ro, "open succeeds")
    if not rw then
        print(string.format("\n%d checks, %d failures", steps, failures))
        __lunet_exit_code = 1
        return
    end

    local _, err = db.exec(rw, "CREATE TABLE t (name TEXT, n INTEGER)")
    check(err == nil, "table created")
    local rows = db.query(rw, "SELECT COUNT(*) AS n FROM t")
    check(rows and rows[1] and rows[1].n == 0, "table is empty")

    -- 1. Prepare a write, exec with params twice: different values must
    --    land — proves reset + clear-bindings between calls.
    local ins, perr = db.prepare(rw, "INSERT INTO t (name, n) VALUES (?, ?)")
    check(ins and not perr, "prepare insert succeeds")
    if ins then
        local r1, e1 = ins:exec("first", 1)
        check(r1 and not e1 and r1.affected_rows == 1, "first exec lands (1 row)")
        local r2, e2 = ins:exec("second", 2)
        check(r2 and not e2 and r2.affected_rows == 1, "second exec on the same statement lands (reset discipline)")
        rows = db.query(rw, "SELECT name, n FROM t ORDER BY rowid")
        check(rows and rows[1] and rows[1].name == "first" and rows[1].n == 1
              and rows[2] and rows[2].name == "second" and rows[2].n == 2,
            "both rows hold their own bound values")
    end

    -- 2. Prepare a read on the rw handle, query with params twice.
    local sel, serr = db.prepare(rw, "SELECT n FROM t WHERE name = ?")
    check(sel and not serr, "prepare select succeeds")
    if sel then
        local q1, qe1 = sel:query("first")
        check(q1 and not qe1 and q1[1] and q1[1].n == 1, "first query with params returns the bound row")
        local q2, qe2 = sel:query("second")
        check(q2 and not qe2 and q2[1] and q2[1].n == 2, "second query with params returns the other row")
        local q3 = sel:query("missing")
        check(q3 and q3[1] == nil, "query with unbound match returns no rows")
    end

    -- 3. Write rejection on the read-only handle happens at PREPARE.
    local wstmt, werr = db.prepare(ro, "INSERT INTO t (name, n) VALUES (?, ?)")
    check(not wstmt and type(werr) == "string", "write SQL on ro fails loudly at prepare (" .. tostring(werr) .. ")")
    -- A read on ro prepares and queries fine.
    local rsel, rerr = db.prepare(ro, "SELECT name FROM t WHERE n = ?")
    check(rsel and not rerr, "read SQL on ro prepares")
    if rsel then
        local q, qe = rsel:query(2)
        check(q and q[1] and q[1].name == "second" and not qe, "read statement executes on ro")
        rsel:close()
    end

    -- 4. Busy: a second call while one is in flight fails loudly, not
    --    silently. Two spawned coroutines: the first yields into the
    --    worker hop; the second then hits the busy flag on the loop
    --    thread before the first can land.
    local landed = 0
    local first_err = nil
    local busy_err = nil
    local reuse_err = nil
    if ins then
        lunet.spawn(function()
            local _, e = ins:exec("concurrent", 3)
            first_err = e
            landed = landed + 1
        end)
        lunet.spawn(function()
            -- Runs while the first exec is still in flight: the entry
            -- point sees the busy flag on the loop thread and returns the
            -- loud error without yielding.
            local _, e = ins:exec("overlapping", 4)
            busy_err = e
            -- Yield the loop thread once so the in-flight exec lands and
            -- its after callback clears the busy flag, then reuse.
            db.query(rw, "SELECT 1")
            local _, e2 = ins:exec("third", 5)
            reuse_err = e2
            landed = landed + 1
        end)
    end
    -- Pump the loop until both coroutines have landed.
    local guard = 0
    while landed < 2 and guard < 1000 do
        guard = guard + 1
        db.query(rw, "SELECT 1")
    end
    check(busy_err == "statement is busy",
        "second concurrent call fails loudly with 'statement is busy' (got " .. tostring(busy_err) .. ")")
    check(first_err == nil, "the in-flight exec landed cleanly")
    check(reuse_err == nil, "statement usable again after the in-flight call lands")
    rows = db.query(rw, "SELECT name, n FROM t ORDER BY rowid")
    check(rows and #rows == 4, "exactly four rows landed (got " .. tostring(rows and #rows) .. ")")

    -- 5. stmt:close() then use = loud error.
    if ins then
        check(ins:close() == nil, "stmt:close succeeds")
        local _, cerr = ins:exec("nope", 6)
        check(cerr ~= nil, "use after close fails loudly (" .. tostring(cerr) .. ")")
        check(ins:close() == nil, "closing a closed statement is a no-op")
    end

    -- 6. GC safety: a statement dropped without close finalizes via __gc.
    do
        local doomed = db.prepare(rw, "SELECT name FROM t WHERE n = ?")
        assert(doomed)
    end
    collectgarbage()
    collectgarbage()
    -- If the finalizer crashed, we never get here.
    rows = db.query(rw, "SELECT COUNT(*) AS n FROM t")
    check(rows and rows[1], "query works after a dropped statement is collected")

    -- 7. Argument guards.
    local co_empty = coroutine.create(function()
        return db.prepare(rw, "")
    end)
    local ok_empty, err_empty = coroutine.resume(co_empty)
    check(ok_empty == false and type(err_empty) == "string",
        "empty SQL raises a loud argument error")

    -- 8. Connection close with statements still open is safe; the
    --    surviving statement fails loudly afterwards.
    local alive, alive_err = db.prepare(rw, "SELECT n FROM t WHERE name = ?")
    check(alive and alive_err == nil, "prepare for the close-ordering step succeeds")
    db.close(rw)
    db.close(ro)
    if alive then
        local _, aerr = alive:query("first")
        check(aerr ~= nil, "statement severed by connection close fails loudly (" .. tostring(aerr) .. ")")
        check(alive:close() == nil, "closing a severed statement is a no-op")
    end

    os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")

    print(string.format("\n%d checks, %d failures", steps, failures))
    __lunet_exit_code = failures > 0 and 1 or 0
end)
