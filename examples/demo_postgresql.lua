--[[
PostgreSQL Database Demo for lunet

QUICK START:
  # Option 1: Set environment variables
  export LUNET_DB_USER=$(whoami)   # or your PostgreSQL username
  ./lunet examples/demo_postgresql.lua

  # Option 2: Edit the db.open() call below to match your setup

Prerequisites:
  1. Build lunet with PostgreSQL support:
       cmake -DLUNET_DB=postgres .. && make

  2. Create the demo database in PostgreSQL:
       psql
       CREATE DATABASE lunet_demo;

Schema (created by this demo):
  CREATE TABLE users (
      id SERIAL PRIMARY KEY,
      name VARCHAR(255) NOT NULL,
      email VARCHAR(255) NOT NULL,
      age INTEGER
  );

Environment Variables:
  LUNET_DB_HOST  - PostgreSQL host (default: localhost)
  LUNET_DB_PORT  - PostgreSQL port (default: 5432)
  LUNET_DB_USER  - PostgreSQL user (default: current system user)
  LUNET_DB_PASS  - PostgreSQL password (default: empty)
  LUNET_DB_NAME  - Database name (default: lunet_demo)
]]

local lunet = require('lunet')
local db = require('lunet.db')

lunet.spawn(function()
    print("=== PostgreSQL Database Demo ===")
    print()
    print("NOTE: This demo requires a running PostgreSQL server.")
    print("      Configure the connection parameters below.")
    print()

    local conn, err = db.open({
        host = os.getenv("LUNET_DB_HOST") or "localhost",
        port = tonumber(os.getenv("LUNET_DB_PORT")) or 5432,
        user = os.getenv("LUNET_DB_USER") or os.getenv("USER") or "postgres",
        password = os.getenv("LUNET_DB_PASS") or "",
        database = os.getenv("LUNET_DB_NAME") or "lunet_demo"
    })

    if not conn then
        print("Failed to connect to PostgreSQL:", err)
        print()
        print("To run this demo:")
        print("  1. Start PostgreSQL server")
        print("  2. Create the database: CREATE DATABASE lunet_demo;")
        print("  3. Update connection parameters above if needed")
        return
    end
    print("Connected to PostgreSQL database: lunet_demo")

    local result, err = db.exec(conn, "DROP TABLE IF EXISTS users")
    if err then
        print("Warning: Could not drop existing table:", err)
    end

    local result, err = db.exec(conn, [[
        CREATE TABLE users (
            id SERIAL PRIMARY KEY,
            name VARCHAR(255) NOT NULL,
            email VARCHAR(255) NOT NULL,
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
            print(("Inserted %s (affected=%d)"):format(user.name, result.affected_rows))
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
