-- Smoke test for the lunet.sqlite3 open contract
--
-- Run after `xmake build lunet-sqlite3`:
--   "$(find build -path '*/release/lunet-run' -type f | head -1)" test/smoke_sqlite3_open.lua
--
-- Covers ticket: precise open semantics — create=WAL|NORMAL, READWRITE-only
-- default (missing file is a loud error), :memory: as the unit-test swap,
-- and the passthrough settings. Files live under .tmp/ so a run never
-- litters the repo root.

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

local function read_journal_mode(conn)
    local rows, err = db.query(conn, "PRAGMA journal_mode")
    if err or not rows or not rows[1] then return nil, err end
    return rows[1].journal_mode
end

os.execute("mkdir -p .tmp")

lunet.spawn(function()
    -- 1. create=WAL on a fresh file: file created, mode is wal.
    local p1 = ".tmp/smoke_open_wal.db"
    os.remove(p1); os.remove(p1 .. "-wal"); os.remove(p1 .. "-shm")
    local rw, ro = db.open({ path = p1, create = "WAL" })
    check(rw and ro, "create=WAL opens a fresh file")
    if rw then
        local mode = read_journal_mode(rw)
        check(mode == "wal", "create=WAL leaves the file in wal mode (got " .. tostring(mode) .. ")")
        -- create=WAL on the existing file again: idempotent, still opens.
        local rw2, ro2, err2 = db.open({ path = p1, create = "WAL" })
        check(rw2 and ro2 and not err2, "create=WAL on an existing WAL file opens (rwc + idempotent pragma)")
        db.destroy(p1)
    end

    -- 2. create=NORMAL on a fresh file: file created, mode untouched
    --    (rollback journal — the SQLite default).
    local p2 = ".tmp/smoke_open_normal.db"
    os.remove(p2); os.remove(p2 .. "-wal"); os.remove(p2 .. "-shm")
    local rw3, ro3 = db.open({ path = p2, create = "NORMAL" })
    check(rw3 and ro3, "create=NORMAL opens a fresh file")
    if rw3 then
        local mode = read_journal_mode(rw3)
        check(mode ~= "wal", "create=NORMAL leaves the journal mode at the default (got " .. tostring(mode) .. ")")
        db.destroy(p2)
    end

    -- 3. No create= on a missing file: loud error.
    local p3 = ".tmp/smoke_open_missing.db"
    os.remove(p3)
    local nrw, nro, nerr = db.open({ path = p3 })
    check(not nrw and not nro and type(nerr) == "string",
        "open without create= on a missing file fails loudly")

    -- 4. No create= on an existing file: opens, journal mode untouched
    --    (the file from step 1 is WAL; plain open must not change it).
    local rw4, ro4, err4 = db.open({ path = p1 })
    check(rw4 and ro4 and not err4, "open without create= on an existing file opens")
    if rw4 then
        local mode = read_journal_mode(rw4)
        check(mode == "wal", "open without create= never touches the journal mode (got " .. tostring(mode) .. ")")
        db.destroy(p1)
    end

    -- 5. :memory: — one connection as both handles; ro sees rw's writes;
    --    never cached (two opens are two private databases).
    local mrw, mro, merr = db.open({ path = ":memory:", create = "WAL" })
    check(mrw and mro and not merr, ":memory: opens with create= ignored")
    if mrw then
        db.exec(mrw, "CREATE TABLE t (v TEXT)")
        db.exec(mrw, "INSERT INTO t VALUES ('x')")
        local rows = db.query(mro, "SELECT v FROM t")
        check(rows and rows[1] and rows[1].v == "x", ":memory: ro sees rw's writes (same connection)")
        local mrw2 = db.open({ path = ":memory:" })
        local rows2 = db.query(mrw2, "SELECT COUNT(*) AS n FROM sqlite_master")
        check(rows2 and rows2[1] and rows2[1].n == 0,
            ":memory: opens are independent (never cached)")
        db.close(mrw2)
    end

    -- 6. Passthroughs land on both connections and are overridable per handle.
    local p6 = ".tmp/smoke_open_pass.db"
    os.remove(p6)
    local rw6, ro6 = db.open({
        path = p6, create = "WAL",
        busy_timeout = 3000, foreign_keys = true, synchronous = "NORMAL",
    })
    check(rw6 and ro6, "open with passthroughs succeeds")
    if rw6 then
        local fk = db.query(rw6, "PRAGMA foreign_keys")
        local fko = db.query(ro6, "PRAGMA foreign_keys")
        check(fk and fk[1] and fk[1].foreign_keys == 1, "foreign_keys=1 applied to rw")
        check(fko and fko[1] and fko[1].foreign_keys == 1, "foreign_keys=1 applied to ro")
        local syn = db.query(rw6, "PRAGMA synchronous")
        check(syn and syn[1] and syn[1].synchronous == 1, "synchronous=NORMAL applied to rw")
        -- per-handle override: last write wins on rw only.
        db.exec(rw6, "PRAGMA busy_timeout = 5000")
        -- PRAGMA busy_timeout's readback column is named "timeout", not
        -- "busy_timeout" (vendor naming — verified against the CLI).
        local bt = db.query(rw6, "PRAGMA busy_timeout")
        check(bt and bt[1] and bt[1].timeout == 5000, "busy_timeout override on rw takes (5000)")
        local bto = db.query(ro6, "PRAGMA busy_timeout")
        check(bto and bto[1] and bto[1].timeout == 3000, "ro keeps the open-time busy_timeout (3000)")
        db.destroy(p6)
    end

    -- 7. Write rejection on a file ro handle is still loud.
    local p7 = ".tmp/smoke_open_ro.db"
    os.remove(p7)
    local rw7, ro7 = db.open({ path = p7, create = "WAL" })
    if rw7 and ro7 then
        local _, werr = db.exec(ro7, "CREATE TABLE nope (id INTEGER)")
        check(werr ~= nil, "write on the ro handle fails loudly (" .. tostring(werr) .. ")")
        db.destroy(p7)
    end

    -- 8. Invalid create= value is a loud argument error.
    local co = coroutine.create(function()
        return db.open({ path = ".tmp/smoke_open_bad.db", create = "MAGIC" })
    end)
    local ok, rerr = coroutine.resume(co)
    check(ok == false and type(rerr) == "string" and rerr:find("WAL", 1, true),
        "create='MAGIC' raises a loud argument error")

    print(string.format("\n%d checks, %d failures", steps, failures))
    if failures > 0 then
        __lunet_exit_code = 1
    else
        __lunet_exit_code = 0
    end
end)
