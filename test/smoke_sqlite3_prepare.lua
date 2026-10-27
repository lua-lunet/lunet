-- Smoke test for the lunet.sqlite3 named statements
--
-- Run after the driver build:
--   "$(find build -path '*/release/lunet-run' -type f | head -1)" test/smoke_sqlite3_prepare.lua
--
-- Covers: prepare on the rw inventory → exec with params twice (the
-- snapshot + reset + rebind discipline is proven by the second run),
-- query with params, the FIFO queue under concurrent same-name callers
-- (distinct results, never a busy error — the reversed mistake of the old
-- design), route rejections on the ro handle, loud use-after-close, GC
-- safety, and close-ordering statements. Files live under .tmp/ so a run
-- never litters the repo root.

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

local function clean(p)
    os.remove(p); os.remove(p .. "-wal"); os.remove(p .. "-shm"); os.remove(p .. "-journal")
end

os.execute("mkdir -p .tmp")
clean(DB_PATH)

local rw, ro, err
lunet.spawn(function()
    rw, ro, err = db.open({ path = DB_PATH, create = "WAL" })
    check(rw and ro and not err, "open succeeds")
    if not rw then
        print(string.format("\n%d checks, %d failures", steps, failures))
        __lunet_exit_code = 1
        return
    end

    local _, cerr = db.exec(rw, "CREATE TABLE t (name TEXT, n INTEGER)")
    check(not cerr, "table created")
    local rows = db.query(rw, "SELECT COUNT(*) AS n FROM t")
    check(rows and rows[1] and rows[1].n == 0, "table is empty")

    -- 1. Prepare a write on the inventory, exec with params twice:
    --    different values must land — snapshot + reset + rebind between
    --    calls.
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
        check(q3 and q3[1] == nil, "query with an unbound match returns no rows")
    end

    -- 3. Routing: the ro handle cannot prepare or exec; a read goes
    --    through query_ro inline.
    local wstmt, werr = db.prepare(ro, "INSERT INTO t (name, n) VALUES (?, ?)")
    check(not wstmt and type(werr) == "table" and werr.op == "route",
        "prepare on ro is a route violation (" .. tostring(werr and werr.message) .. ")")
    local _, ro_exec_err = db.query_ro(ro, "INSERT INTO t (name, n) VALUES ('x', 9)")
    check(ro_exec_err ~= nil and ro_exec_err.code == 8,
        "a write sent to the ro connection through query_ro reports SQLITE_READONLY")

    -- 4. Concurrent same-name callers queue: two spawned coroutines, both
    --    exec through ins, BOTH land with their own bound values. The old
    --    design failed with 'statement is busy'; the new design queues.
    local landed_first, landed_second = nil, nil
    if ins then
        lunet.spawn(function()
            local _, e = ins:exec("concurrent", 3)
            landed_first = (e == nil)
        end)
        lunet.spawn(function()
            local _, e = ins:exec("overlapping", 4)
            landed_second = (e == nil)
        end)
        local guard = 0
        while (landed_first == nil or landed_second == nil) and guard < 2000 do
            guard = guard + 1
            db.query(rw, "SELECT 1")
        end
        check(landed_first and landed_second,
            "two concurrent same-name callers both land (FIFO queue, no busy errors)")
        rows = db.query(rw, "SELECT n FROM t WHERE name = 'concurrent'")
        check(rows and rows[1] and rows[1].n == 3, "the first caller's snapshot landed")
        rows = db.query(rw, "SELECT n FROM t WHERE name = 'overlapping'")
        check(rows and rows[1] and rows[1].n == 4, "the second caller's snapshot landed")
    end

    -- 5. stmt:close() then use = loud error.
    if ins then
        check(ins:close() == nil, "stmt:close succeeds")
        local _, close_err = ins:exec("nope", 6)
        check(close_err ~= nil, "use after close fails loudly (" .. tostring(close_err and close_err.message) .. ")")
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
        check(aerr ~= nil, "statement severed by connection close fails loudly ("
              .. tostring(aerr and aerr.message) .. ")")
        check(alive:close() == nil, "closing a severed statement is a no-op")
    end

    clean(DB_PATH)

    print(string.format("\n%d checks, %d failures", steps, failures))
    __lunet_exit_code = failures > 0 and 1 or 0
end)
