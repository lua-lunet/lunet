--[[
SQLite3 Database Demo for lunet

Prerequisites:
  Build core + sqlite3 driver:
    xmake f -m release -y
    xmake build
    xmake build lunet-sqlite3

Schema (created automatically):
  CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL,
      age INTEGER
  );

Usage:
  LUNET_BIN=$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)
  "$LUNET_BIN" examples/03_db_sqlite3.lua

Demonstrates the read/write split: open() returns TWO connections — a
read-write handle (worker pool) and a read-only handle (queries run inline
on the loop thread). The split needs a file path: on ":memory:" a second
READONLY connection is a new empty database, not a reader on the writer's
data.
]]

local lunet = require("lunet")
local db = require("lunet.sqlite3")

local DB_PATH = "03_db_sqlite3_demo.db"

lunet.spawn(function()
    print("=== SQLite3 Database Demo ===")
    print()

    os.remove(DB_PATH)
    os.remove(DB_PATH .. "-wal")
    os.remove(DB_PATH .. "-shm")

    local rw, ro, err = db.open({ path = DB_PATH })
    if not rw then
        error("Failed to open database: " .. tostring(err))
    end
    assert(type(rw) == "userdata" and type(ro) == "userdata",
        "open must return two connections (rw, ro)")
    print("Opened " .. DB_PATH .. " (rw + read-only ro)")

    -- One-time setup on the writer: WAL makes readers uncontended
    -- against the single writer.
    local wal = db.exec(rw, "PRAGMA journal_mode=WAL")
    if wal then print("Journal mode: WAL") end

    local _, result
    _, err = db.exec(rw, [[
        CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL,
            age INTEGER
        )
    ]])
    if err then
        print("Failed to create table:", err)
        db.close(rw)
        db.close(ro)
        return
    end
    print("Created users table")

    local users = {
        { name = "Alice", email = "alice@example.com", age = 28 },
        { name = "Bob", email = "bob@example.com", age = 35 },
        { name = "O'Brien", email = "obrien@example.com", age = 42 }
    }

    for _, user in ipairs(users) do
        result, err = db.exec_params(
            rw,
            "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
            user.name,
            user.email,
            user.age
        )
        if err then
            print("Failed to insert user:", err)
        else
            print(("Inserted %s (id=%d)"):format(user.name, result.last_insert_id))
        end
    end
    print()

    -- Reads go through the read-only handle: inline on the loop
    -- thread, no worker hop.
    print("Querying all users via ro:")
    local rows
    rows, err = db.query(ro, "SELECT id, name, email, age FROM users ORDER BY id")
    assert(not err, "ro query failed: " .. tostring(err))
    assert(#rows == 3, "expected 3 users, got " .. tostring(#rows))
    for _, row in ipairs(rows) do
        print(("  [%d] %s <%s> age=%d"):format(row.id, row.name, row.email, row.age))
    end
    print()

    print("Querying users older than 30 via ro (query_params):")
    rows, err = db.query_params(ro, "SELECT id, name, age FROM users WHERE age > ? ORDER BY age", 30)
    assert(not err, "ro query_params failed: " .. tostring(err))
    for _, row in ipairs(rows) do
        print(("  [%d] %s age=%d"):format(row.id, row.name, row.age))
    end
    print()

    -- A write mis-routed to ro parses at prepare and fails LOUDLY at
    -- step with SQLITE_READONLY — it can never commit silently.
    print("Mis-routed write via ro (must fail loudly):")
    local _, werr = db.exec(ro, "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
                            "Mallory", "mallory@example.com", 99)
    assert(werr, "write on ro must fail (SQLITE_READONLY)")
    print("  Rejected as expected: " .. werr)
    rows, err = db.query(ro, "SELECT COUNT(*) AS n FROM users")
    assert(not err and rows[1].n == 3, "mis-routed write must not commit")
    print()

    print("Updating Bob's age to 36 (via rw)...")
    result, err = db.exec_params(rw, "UPDATE users SET age = ? WHERE name = ?", 36, "Bob")
    if err then
        print("Update failed:", err)
    else
        print(("  Affected rows: %d"):format(result.affected_rows))
    end
    print()

    print("Final user list (via ro):")
    rows, err = db.query(ro, "SELECT id, name, email, age FROM users ORDER BY id")
    assert(not err, "ro query failed: " .. tostring(err))
    for _, row in ipairs(rows) do
        print(("  [%d] %s <%s> age=%d"):format(row.id, row.name, row.email, row.age))
    end

    db.close(rw)
    db.close(ro)

    -- The convenience open caches the pair keyed on the path: a second
    -- open of the same file returns the SAME handles, destroy(path)
    -- closes both and clears the entry, open_raw always opens fresh.
    -- See ext/sqlite3/SQLITE.md.
    print()
    print("Cached open + destroy(path) + open_raw...")
    local cw1, co1, cerr = db.open({ path = DB_PATH })
    assert(cw1 and co1 and not cerr, "cached open failed: " .. tostring(cerr))
    local cw2, co2 = db.open({ path = DB_PATH })
    assert(cw1 == cw2 and co1 == co2, "repeat open must return the same pair")
    local raw1, raw2, rerr = db.open_raw({ path = DB_PATH })
    assert(raw1 and raw2 and not rerr, "open_raw failed: " .. tostring(rerr))
    assert(raw1 ~= cw1, "open_raw must not return cached handles")
    db.destroy(DB_PATH)
    local cw3 = db.open({ path = DB_PATH })
    assert(cw3 ~= nil and cw3 ~= cw1, "post-destroy open must be a fresh pair")
    print("  same pair on repeat open; open_raw fresh; destroy clears")
    db.destroy(DB_PATH)

    os.remove(DB_PATH)
    os.remove(DB_PATH .. "-wal")
    os.remove(DB_PATH .. "-shm")
    print()
    print("Database closed. Demo complete!")
end)
