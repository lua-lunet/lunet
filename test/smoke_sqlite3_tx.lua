-- Smoke test for lunet.sqlite3_tx (transaction wrapper, issue #119)
--
-- Run after `xmake build lunet-sqlite3 && xmake build-release`:
--   "$(find build -path '*/release/lunet-run' -type f | head -1)" test/smoke_sqlite3_tx.lua
--
-- Needs no server, which is why this one is a committed test. The equivalent
-- checks for postgres and mysql require a live database, so they are run by
-- hand from .tmp/ instead -- see ext/postgres/README.md and
-- ext/mysql/README.md for the methodology.

local lunet = require("lunet")

-- Resolve the wrapper from the source tree. In a release archive it sits
-- next to sqlite3.so as lunet/sqlite3_tx.lua and plain require() finds it.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local wrapper = script_dir .. "/../ext/sqlite3/sqlite3_tx.lua"
package.preload["lunet.sqlite3_tx"] = assert(loadfile(wrapper))

local db = require("lunet.sqlite3")
local tx = require("lunet.sqlite3_tx")

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

lunet.spawn(function()
    local path = os.tmpname() .. ".db"
    local conn, err = db.open({ path = path })
    if not conn then
        print("cannot open sqlite db: " .. tostring(err))
        os.exit(1)
    end

    assert(db.exec(conn, [[
        CREATE TABLE nodes (
            path TEXT PRIMARY KEY,
            version INTEGER NOT NULL
        )
    ]]))
    assert(db.exec(conn, "INSERT INTO nodes (path, version) VALUES (?, ?)", "/src", 1))
    assert(db.exec(conn, "INSERT INTO nodes (path, version) VALUES (?, ?)", "/dst", 1))

    local function count(p)
        local rows = db.query(conn, "SELECT COUNT(*) AS n FROM nodes WHERE path = ?", p)
        return tonumber(rows[1].n)
    end

    print("\n=== commit path ===")
    local res, terr = tx.transaction(conn, function(t)
        t.exec("DELETE FROM nodes WHERE path = ?", "/dst")
        local r = t.exec("UPDATE nodes SET path = ? WHERE path = ? AND version = ?",
                         "/dst", "/src", 1)
        check(r.affected_rows == 1, "t.exec reports affected_rows inside tx")
        return "moved"
    end, "IMMEDIATE")
    check(res == "moved", "returns fn's result on COMMIT")
    check(terr == nil, "no error on COMMIT")
    check(count("/dst") == 1, "committed row is visible")
    check(count("/src") == 0, "committed delete is visible")

    print("\n=== abort by returning nil (the CAS-miss case) ===")
    -- Put the rows back so the abort has something to undo.
    assert(db.exec(conn, "UPDATE nodes SET path = ? WHERE path = ?", "/src", "/dst"))
    assert(db.exec(conn, "INSERT INTO nodes (path, version) VALUES (?, ?)", "/dst", 1))

    local res2, err2 = tx.transaction(conn, function(t)
        t.exec("DELETE FROM nodes WHERE path = ?", "/dst")
        local r = t.exec("UPDATE nodes SET path = ? WHERE path = ? AND version = ?",
                         "/dst", "/src", 999)  -- version mismatch -> 0 rows
        if r.affected_rows == 0 then
            return nil, "version conflict"
        end
        return true
    end, "IMMEDIATE")
    check(res2 == nil, "returns nil when fn aborts")
    check(err2 ~= nil and err2.message == "version conflict", "surfaces the abort reason")
    check(err2 ~= nil and err2.poisoned == false, "a clean rollback is not poisoned")
    check(count("/dst") == 1, "the DELETE was rolled back too")
    check(count("/src") == 1, "the source row is untouched")

    print("\n=== raise inside fn ===")
    local res3, err3 = tx.transaction(conn, function(t)
        t.exec("DELETE FROM nodes WHERE path = ?", "/dst")
        error("boom", 0)
    end, "IMMEDIATE")
    check(res3 == nil, "returns nil when fn raises")
    check(err3 ~= nil and tostring(err3) == "boom", "propagates the raised message via tostring")
    check(count("/dst") == 1, "rolled back the work done before the raise")

    print("\n=== statement error inside fn ===")
    local res4, err4 = tx.transaction(conn, function(t)
        t.exec("DELETE FROM nodes WHERE path = ?", "/dst")
        t.query("SELECT * FROM no_such_table")
        return true
    end, "IMMEDIATE")
    check(res4 == nil, "returns nil on a statement error")
    check(err4 ~= nil and err4.message:find("no_such_table") ~= nil,
          "surfaces the driver error text")
    check(count("/dst") == 1, "rolled back after the statement error")

    print("\n=== err ergonomics and guards ===")
    check(("prefix: " .. err4) :find("no_such_table") ~= nil, "err supports concatenation")
    local _, e5 = tx.transaction(conn, function() return true end, "NONSENSE")
    check(e5 ~= nil and e5.message:find("invalid transaction mode") ~= nil,
          "rejects an invalid locking mode")
    local _, e6 = tx.transaction(nil, function() return true end)
    check(e6 ~= nil and e6.message:find("requires a connection") ~= nil,
          "rejects a nil connection")
    local _, e7 = tx.transaction(conn, "not a function")
    check(e7 ~= nil and e7.message:find("requires a function") ~= nil,
          "rejects a non-function body")

    print("\n=== connection still usable after all that ===")
    check(count("/src") == 1, "connection works after aborted transactions")

    db.close(conn)
    os.remove(path)

    print(string.format("\n%d checks, %d failures", steps, failures))
    if failures > 0 then os.exit(1) end
    print("smoke_sqlite3_tx: PASS")
end)
