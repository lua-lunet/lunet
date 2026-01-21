--[[
SQLite3 Database Demo for lunet

Prerequisites:
  Build lunet with SQLite3 support:
    cmake -DLUNET_DB=sqlite3 .. && make

Schema (created automatically in-memory):
  CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL,
      age INTEGER
  );

Usage:
  ./lunet examples/sqlite3.lua
]]

local lunet = require('lunet')
local db = require('lunet.db')

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
        local sql = "INSERT INTO users (name, email, age) VALUES ('" 
            .. db.escape(user.name) .. "', '" 
            .. db.escape(user.email) .. "', " 
            .. user.age .. ")"
        local result, err = db.exec(conn, sql)
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

    print("Updating Bob's age to 36...")
    local result, err = db.exec(conn, "UPDATE users SET age = 36 WHERE name = 'Bob'")
    if err then
        print("Update failed:", err)
    else
        print(("  Affected rows: %d"):format(result.affected_rows))
    end
    print()

    print("Deleting O'Brien (testing escape)...")
    local result, err = db.exec(conn, "DELETE FROM users WHERE name = '" .. db.escape("O'Brien") .. "'")
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
