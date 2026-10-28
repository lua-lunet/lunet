-- Smoke test for the lunet.sqlite3 open contract
--
-- Run after `xmake build lunet-sqlite3`:
--   "$(find build -path '*/release/lunet-run' -type f | head -1)" test/smoke_sqlite3_open.lua
--
-- Covers: create=WAL|NORMAL, READWRITE-only default (missing file is a
-- loud failure with SQLite codes), journal mode untouched without create,
-- :memory: aliasing through the owner worker, the passthrough settings,
-- the mutex option, and the loud unknown-option check. Files live under
-- .tmp/ so a run never litters the repo root.

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

local function journal_mode_of(conns)
    local rows = db.query_ro(conns.ro, "PRAGMA journal_mode")
    return rows and rows[1] and rows[1].journal_mode
end

local function clean(p)
    os.remove(p); os.remove(p .. "-wal"); os.remove(p .. "-shm"); os.remove(p .. "-journal")
end

os.execute("mkdir -p .tmp")

local rw, ro, err                       -- re-used handles
lunet.spawn(function()
    -- 1. create=WAL on a fresh file: file created, verified wal.
    local p1 = ".tmp/smoke_open_wal.db"
    clean(p1)
    rw, ro, err = db.open({ path = p1, create = "WAL" })
    check(rw and ro and not err, "create=WAL opens a fresh file")
    check(journal_mode_of({ rw = rw, ro = ro }) == "wal", "create=WAL verified the journal mode is wal")
    -- create=WAL on an existing WAL file again: idempotent reopen.
    local rw2, ro2, err2 = db.open({ path = p1, create = "WAL" })
    check(rw2 and ro2 and not err2, "create=WAL on an existing WAL file opens (idempotent pragma)")
    db.close(rw2); db.close(ro2)
    check(journal_mode_of({ rw = rw, ro = ro }) == "wal", "journal mode still wal after the second open")

    -- 2. create=NORMAL on a fresh file: file created, default journal mode.
    local p2 = ".tmp/smoke_open_normal.db"
    clean(p2)
    local rw3, ro3, err3 = db.open({ path = p2, create = "NORMAL" })
    check(rw3 and ro3 and not err3, "create=NORMAL opens a fresh file")
    check(journal_mode_of({ rw = rw3, ro = ro3 }) ~= "wal",
        "create=NORMAL leaves the journal mode at the SQLite default")
    db.close(rw3); db.close(ro3)
    clean(p2)

    -- 3. No create= on a missing file: loud failure, both handles nil,
    --    SQLite codes carried on the error table.
    local p3 = ".tmp/smoke_open_missing.db"
    clean(p3)
    local nrw, nro, nerr = db.open({ path = p3 })
    check(not nrw and not nro and type(nerr) == "table",
        "open without create= on a missing file returns (nil, nil, err)")
    check(nerr and nerr.message ~= nil and nerr.code ~= nil,
        "the open failure carries message + SQLite code")

    -- 4. No create= on an existing file: opens, journal mode untouched.
    rw, ro, err = db.open({ path = p1 })
    check(rw and ro and not err, "open without create= on an existing file opens")
    check(journal_mode_of({ rw = rw, ro = ro }) == "wal",
        "open without create= never touches the journal mode")

    -- 5. :memory: — one physical connection for both logical paths,
    --    serialized through its owner worker; ro does not enforce
    --    read-only there; two opens are two private databases.
    local mrw4, mro4, merr4 = db.open({ path = ":memory:" })
    check(mrw4 and mro4 and not merr4, ":memory: opens")
    db.exec(mrw4, "CREATE TABLE t (v TEXT)")
    db.exec(mrw4, "INSERT INTO t VALUES ('x')")
    local rows = db.query_ro(mro4, "SELECT v FROM t")
    check(rows and rows[1] and rows[1].v == "x",
        ":memory: ro logical path sees rw's writes (owner-serialized)")
    local _, wmem_err = db.query_ro(mro4, "INSERT INTO t VALUES ('y')")
    check(not wmem_err, ":memory: write via query_ro succeeds (no read-only enforcement)")
    local rows_mem = db.query_ro(mro4, "SELECT COUNT(*) AS n FROM t")
    check(rows_mem and rows_mem[1] and rows_mem[1].n == 2, ":memory: write landed on the connection")
    db.close(mrw4); db.close(mro4)
    local mrw2, mro2 = db.open({ path = ":memory:" })
    db.exec(mrw2, "CREATE TABLE t (v TEXT)")
    local rows2 = db.query_ro(mro2, "SELECT COUNT(*) AS n FROM sqlite_master")
    check(rows2 and rows2[1] and rows2[1].n == 1,
        ":memory: opens are independent private databases (sqlite_master holds exactly the new table)")

    -- 6. Passthroughs land on both connections; per-handle override wins on rw.
    local p6 = ".tmp/smoke_open_pass.db"
    clean(p6)
    local rw6, ro6 = db.open({
        path = p6, create = "WAL",
        busy_timeout = 3000, foreign_keys = true, synchronous = "NORMAL",
    })
    check(rw6 and ro6, "open with passthroughs succeeds")
    local fk = db.query_ro(ro6, "PRAGMA foreign_keys")
    check(fk and fk[1] and fk[1].foreign_keys == 1, "foreign_keys=1 applied")
    db.exec(rw6, "PRAGMA busy_timeout = 5000")
    -- PRAGMA busy_timeout's readback column is named "timeout" (vendor naming).
    local bt = db.query_ro(ro6, "PRAGMA busy_timeout")
    check(bt and bt[1] and bt[1].timeout == 3000, "ro keeps the open-time busy_timeout (3000)")
    db.close(rw6); db.close(ro6)
    clean(p6)

    -- 7. Helper: synchronous=NORMAL default, caller value wins.
    local p7 = ".tmp/smoke_open_helper.db"
    clean(p7)
    local hrw, hro, herr = db.connect(p7, { create = "WAL" })
    check(hrw and hro and not herr, "helper opens")
    local hsyn = db.query_ro(hro, "PRAGMA synchronous")
    check(hsyn and hsyn[1] and hsyn[1].synchronous == 1, "helper default synchronous=NORMAL")
    db.close(hrw); db.close(hro)
    clean(p7)
    hrw, hro, herr = db.connect(p7, { create = "WAL", synchronous = "FULL" })
    check(hrw and hro and not herr, "helper opens with an override")
    hsyn = db.query_ro(hro, "PRAGMA synchronous")
    check(hsyn and hsyn[1] and hsyn[1].synchronous == 2, "helper override synchronous=FULL wins")
    db.close(hrw); db.close(hro)
    clean(p7)

    -- 8. mutex=nomutex / fullmutex are explicit choices; invalid is loud.
    local p8 = ".tmp/smoke_open_mutex.db"
    clean(p8)
    rw, ro, err = db.open({ path = p8, create = "NORMAL", mutex = "nomutex" })
    check(rw and ro and not err, "mutex=nomutex opens")
    db.close(rw); db.close(ro)
    clean(p8)
    rw, ro, err = db.open({ path = p8, create = "NORMAL", mutex = "fullmutex" })
    check(rw and ro and not err, "mutex=fullmutex opens")
    db.close(rw); db.close(ro)
    clean(p8)
    local co = coroutine.create(function()
        return db.open({ path = p8, mutex = "YESSIR" })
    end)
    local ok, merr = coroutine.resume(co)
    check(ok == false and tostring(merr):find("mutex", 1, true) ~= nil,
        "invalid mutex value raises a loud argument error")

    -- 9. Unknown option name is loud.
    co = coroutine.create(function()
        return db.open({ path = p8, bogus_option = 1 })
    end)
    ok, merr = coroutine.resume(co)
    check(ok == false and tostring(merr):find("bogus_option", 1, true) ~= nil,
        "unknown option raises a loud argument error")

    -- 10. Write on the file ro handle via query_ro: SQLite's own
    --     SQLITE_READONLY; the rw-only calls are route violations.
    local p10 = ".tmp/smoke_open_ro.db"
    clean(p10)
    local rw10, ro10 = db.open({ path = p10, create = "WAL" })
    if rw10 and ro10 then
        local _, werr = db.query_ro(ro10, "CREATE TABLE nope (id INTEGER)")
        check(werr ~= nil and werr.code == 8,
            "write via query_ro on the ro handle reports SQLITE_READONLY (8)")
        local _, rerr = db.query(ro10, "SELECT 1")
        check(rerr ~= nil and rerr.op == "route", "query on the ro handle is a route violation")
        db.close(rw10); db.close(ro10)
        clean(p10)
    end

    -- 11. Invalid create value is a loud argument error.
    co = coroutine.create(function()
        return db.open({ path = ".tmp/smoke_open_bad.db", create = "MAGIC" })
    end)
    ok, merr = coroutine.resume(co)
    check(ok == false and tostring(merr):find("WAL", 1, true) ~= nil,
        "create='MAGIC' raises a loud argument error")

    -- teardown of the handle from steps 1 & 4
    db.close(rw); db.close(ro)
    clean(p1)
    clean(p3)

    print(string.format("\n%d checks, %d failures", steps, failures))
    __lunet_exit_code = (failures == 0) and 0 or 1
end)
