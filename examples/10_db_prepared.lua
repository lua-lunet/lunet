--[[
SQLite3 Named-Statement Inventory Demo for lunet

Prerequisites:
  Build core + sqlite3 driver:
    xmake f -m release -y
    xmake build
    xmake build lunet-sqlite3

Usage:
  LUNET_BIN=$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)
  "$LUNET_BIN" examples/10_db_prepared.lua

Demonstrates the startup inventory: the named statements this application
issues are declared in one table, prepared once on the rw worker before
serving, executed per request with fresh bound parameters (each call
snapshots its own parameters), and closed through the FIFO at shutdown.
Short point reads run inline on the ro handle instead.

Whether named statements are worth it: for a trivial statement the
per-call prepare is unmeasurable; for a complex or expensive statement
issued at high rate it can matter. Read the SQLite documentation and
decide for your own workload — there is no magic.
]]

local lunet = require("lunet")
local db = require("lunet.sqlite3")

local DB_PATH = ".tmp/10_db_prepared_demo.db"

-- The application's statement inventory, declared once at the top:
-- the statements are visible in one place and prepared on the rw owner
-- before the application serves any request.
local INVENTORY = {
    insert_user = "INSERT INTO users (name, age) VALUES (?, ?)",
    users_older_than = "SELECT id, name FROM users WHERE age > ? ORDER BY age",
}

lunet.spawn(function()
    print("=== SQLite3 Named-Statement Inventory Demo ===")
    print()

    os.execute("mkdir -p .tmp")
    os.remove(DB_PATH)
    os.remove(DB_PATH .. "-wal")
    os.remove(DB_PATH .. "-shm")

    local rw, ro, err = db.open({ path = DB_PATH, create = "WAL" })
    if not rw then
        error("Failed to open database: " .. (err and err.message or tostring(err)))
    end
    print("Opened " .. DB_PATH)

    -- Schema setup is a one-off ad-hoc statement: plain exec is right.
    local _, cerr = db.exec(rw, [[
        CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            age INTEGER
        )
    ]])
    assert(not cerr, "create failed: " .. (cerr and cerr.message or tostring(cerr)))

    -- Prepare the inventory BEFORE serving. Each prepare waits for the
    -- rw worker to compile the SQL on the owner thread.
    local stmts = {}
    for name, sql in pairs(INVENTORY) do
        local stmt, perr = db.prepare(rw, sql)
        assert(stmt, "prepare " .. name .. " failed: " .. (perr and perr.message or tostring(perr)))
        stmts[name] = stmt
    end
    print("Inventory prepared on the rw worker")

    -- Named statements: every call snapshots its own parameters and the
    -- worker rebinds the statement per call.
    local users = {
        { name = "Alice", age = 28 },
        { name = "Bob", age = 35 },
        { name = "O'Brien", age = 42 }
    }
    for _, user in ipairs(users) do
        local result, xerr = stmts.insert_user:exec(user.name, user.age)
        assert(not xerr, "insert failed: " .. (xerr and xerr.message or tostring(xerr)))
        print(("Inserted %s (id=%d)"):format(user.name, result.last_insert_id))
    end

    -- A read through the same statement rides the same FIFO.
    local rows, qerr
    for _, threshold in ipairs({ 30, 40 }) do
        rows, qerr = stmts.users_older_than:query(threshold)
        assert(rows, "filter failed: " .. (qerr and qerr.message or tostring(qerr)))
        print()
        print(("Users older than %d (named statement):"):format(threshold))
        for _, row in ipairs(rows) do
            print(("  %s"):format(row.name))
        end
    end

    -- The named statement reaches back to every committed row too.
    rows, qerr = stmts.users_older_than:query(0)
    assert(rows, "read failed: " .. (qerr and qerr.message or tostring(qerr)))
    print()
    print("All users (same named statement, fresh parameters):")
    for _, row in ipairs(rows) do
        print(("  [%d] %s"):format(row.id, row.name))
    end

    -- Short point reads do not need a statement: query_ro runs inline on
    -- the loop thread with a transient statement per call.
    print()
    local points, rerr = db.query_ro(ro, "SELECT COUNT(*) AS n FROM users")
    assert(points, "point read failed: " .. (rerr and rerr.message or tostring(rerr)))
    print(("Point read on ro: %d users"):format(points[1].n))

    -- Routing is the API: the ro handle cannot run the rw-only calls.
    print()
    local _, route_err = db.prepare(ro, "SELECT 1")
    assert(route_err and route_err.op == "route", "prepare on ro must be a route violation")
    print("prepare on ro rejected as a route violation: " .. route_err.message)
    -- And a write sent to the ro connection through query_ro is SQLite's
    -- own read-only rejection at step.
    local _, werr = db.query_ro(ro, "INSERT INTO users (name, age) VALUES ('Mallory', 99)")
    assert(werr and werr.code == 8, "write on ro must fail with SQLITE_READONLY")
    print("write via query_ro on ro rejected: " .. werr.message)

    -- Close the inventory one statement at a time; the closes go through
    -- the same FIFO as the calls.
    for name in pairs(stmts) do
        assert(stmts[name]:close() == nil, "close " .. name .. " failed")
    end
    print()
    print("Inventory closed")

    -- Use after close fails loudly.
    local _, after_close_err = stmts.insert_user:exec("Nobody", 0)
    assert(after_close_err, "use after close must fail")
    print("Use after close rejected: " .. after_close_err.message)

    db.close(rw)
    db.close(ro)

    os.remove(DB_PATH)
    os.remove(DB_PATH .. "-wal")
    os.remove(DB_PATH .. "-shm")
    print()
    print("Statements closed, database closed. Demo complete!")
end)
