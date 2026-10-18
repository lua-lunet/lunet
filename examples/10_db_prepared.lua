--[[
SQLite3 Prepared Statement Demo for lunet

Prerequisites:
  Build core + sqlite3 driver:
    xmake f -m release -y
    xmake build
    xmake build lunet-sqlite3

Usage:
  LUNET_BIN=$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)
  "$LUNET_BIN" examples/10_db_prepared.lua

Demonstrates the explicit prepared-statement API: a static table of the
queries this application issues, prepared once at open, executed per
request with fresh bound parameters, closed at shutdown.

Whether prepared statements are worth it: for a trivial statement the
per-call prepare is unmeasurable; for a complex or expensive statement
issued at high rate it can matter. Read the SQLite documentation and
decide for your own workload — there is no magic.
]]

local lunet = require("lunet")
local db = require("lunet.sqlite3")

local DB_PATH = ".tmp/10_db_prepared_demo.db"

-- The application's statement inventory, declared once at the top:
-- this is the whole point of the explicit API — the queries are visible
-- in one place and prepared exactly where the connection opens.
local QUERIES = {
    create_users = [[
        CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            age INTEGER
        )
    ]],
    insert_user = "INSERT INTO users (name, age) VALUES (?, ?)",
    list_users = "SELECT id, name, age FROM users ORDER BY id",
    users_older_than = "SELECT id, name FROM users WHERE age > ? ORDER BY age",
    update_age = "UPDATE users SET age = ? WHERE name = ?",
}

lunet.spawn(function()
    print("=== SQLite3 Prepared Statement Demo ===")
    print()

    os.execute("mkdir -p .tmp")
    os.remove(DB_PATH)
    os.remove(DB_PATH .. "-wal")
    os.remove(DB_PATH .. "-shm")

    local rw, ro, err = db.open({ path = DB_PATH, create = "WAL" })
    if not rw then
        error("Failed to open database: " .. tostring(err))
    end
    print("Opened " .. DB_PATH)

    -- Prepare-at-open. Schema setup is a one-off: plain exec is right for it.
    local _, cerr = db.exec(rw, QUERIES.create_users)
    assert(not cerr, "create failed: " .. tostring(cerr))

    -- Statements bound to rw ride the worker pool; the insert is prepared
    -- once and executed per user with fresh parameters.
    local ins, perr = db.prepare(rw, QUERIES.insert_user)
    assert(ins, "prepare insert failed: " .. tostring(perr))

    local users = {
        { name = "Alice", age = 28 },
        { name = "Bob", age = 35 },
        { name = "O'Brien", age = 42 }
    }
    for _, user in ipairs(users) do
        local result, xerr = ins:exec(user.name, user.age)
        assert(not xerr, "insert failed: " .. tostring(xerr))
        print(("Inserted %s (id=%d)"):format(user.name, result.last_insert_id))
    end

    -- A read statement on the read-only handle runs inline on the loop
    -- thread, matching that handle's semantics.
    local list, qerr = db.prepare(ro, QUERIES.list_users)
    assert(list, "prepare list failed: " .. tostring(qerr))
    local rows
    rows, err = list:query()
    assert(not err, "list failed: " .. tostring(err))
    print()
    print("All users via a prepared read:")
    for _, row in ipairs(rows) do
        print(("  [%d] %s age=%d"):format(row.id, row.name, row.age))
    end

    -- Reset discipline: the same statement, executed again with different
    -- parameters, is the whole point of the API.
    local older, oerr = db.prepare(ro, QUERIES.users_older_than)
    assert(older, "prepare filter failed: " .. tostring(oerr))
    for _, threshold in ipairs({ 30, 40 }) do
        rows, err = older:query(threshold)
        assert(not err, "filter failed: " .. tostring(err))
        print()
        print(("Users older than %d:"):format(threshold))
        for _, row in ipairs(rows) do
            print(("  %s"):format(row.name))
        end
    end

    -- Write SQL prepared on the read-only handle is rejected loudly at
    -- PREPARE time — earlier than the step-time failure of a mis-routed
    -- plain exec.
    print()
    local _, werr = db.prepare(ro, QUERIES.update_age)
    assert(werr, "write SQL on ro must fail at prepare")
    print("Write SQL on ro rejected at prepare: " .. werr)

    assert(ins:close() == nil, "insert close failed")
    assert(list:close() == nil, "list close failed")
    assert(older:close() == nil, "filter close failed")

    -- Use after close fails loudly.
    local _, after_close_err = ins:exec("Nobody", 0)
    assert(after_close_err, "use after close must fail")
    print("Use after close rejected: " .. after_close_err)

    db.close(rw)
    db.close(ro)

    os.remove(DB_PATH)
    os.remove(DB_PATH .. "-wal")
    os.remove(DB_PATH .. "-shm")
    print()
    print("Statements closed, database closed. Demo complete!")
end)
