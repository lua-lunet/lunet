--[[
SQLite3 Database Demo for lunet

Prerequisites:
  Build core + sqlite3 driver:
    xmake f -m release -y
    xmake build
    xmake build lunet-sqlite3

Schema (created automatically in-memory):
  CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL,
      age INTEGER
  );

Usage:
  LUNET_BIN=$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)
  "$LUNET_BIN" examples/03_db_sqlite3.lua
]]

local lunet = require("lunet")
local db = require("lunet.sqlite3")

lunet.spawn(function()
    print("=== SQLite3 Database Demo ===")
    print()

    local conn, err = db.open({ path = ":memory:" })
    if not conn then
        print("Failed to open database:", err)
        return
    end
    print("Connected to in-memory SQLite database")

    local result, err = db.exec(conn, [[
        CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL,
            age INTEGER
        )
    ]])
    if err then
        print("Failed to create table:", err)
        db.close(conn)
        return
    end
    print("Created users table")

    local users = {
        { name = "Alice", email = "alice@example.com", age = 28 },
        { name = "Bob", email = "bob@example.com", age = 35 },
        { name = "O'Brien", email = "obrien@example.com", age = 42 }
    }

    for _, user in ipairs(users) do
        local result, err = db.exec_params(
            conn,
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

    print("Querying all users:")
    local rows, err = db.query(conn, "SELECT id, name, email, age FROM users ORDER BY id")
    if err then
        print("Query failed:", err)
    else
        for _, row in ipairs(rows) do
            print(("  [%d] %s <%s> age=%d"):format(row.id, row.name, row.email, row.age))
        end
    end
    print()

    print("Querying users older than 30 (query_params):")
    local rows, err = db.query_params(conn, "SELECT id, name, age FROM users WHERE age > ? ORDER BY age", 30)
    if err then
        print("Query failed:", err)
    else
        for _, row in ipairs(rows) do
            print(("  [%d] %s age=%d"):format(row.id, row.name, row.age))
        end
    end
    print()

    print("Updating Bob's age to 36...")
    local result, err = db.exec_params(conn, "UPDATE users SET age = ? WHERE name = ?", 36, "Bob")
    if err then
        print("Update failed:", err)
    else
        print(("  Affected rows: %d"):format(result.affected_rows))
    end
    print()

    print("Deleting O'Brien...")
    local result, err = db.exec_params(conn, "DELETE FROM users WHERE name = ?", "O'Brien")
    if err then
        print("Delete failed:", err)
    else
        print(("  Affected rows: %d"):format(result.affected_rows))
    end
    print()

    print("Final user list:")
    local rows, err = db.query(conn, "SELECT id, name, email, age FROM users ORDER BY id")
    if err then
        print("Query failed:", err)
    else
        for _, row in ipairs(rows) do
            print(("  [%d] %s <%s> age=%d"):format(row.id, row.name, row.email, row.age))
        end
    end

    db.close(conn)
    print()
    print("Database closed. Demo complete!")
end)
