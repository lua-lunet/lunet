-- Smoke test for PostgreSQL driver
-- Run: ./build/lunet test/smoke_postgres.lua
-- Requires: PostgreSQL running on localhost:5432

local lunet = require("lunet")
local db = require("lunet.postgres")

local function test_postgres()
    print("=== PostgreSQL Smoke Test ===")

    -- Test 1: Open connection
    print("1. Opening connection...")
    local conn, err = db.open({
        host = "127.0.0.1",
        port = 5432,
        user = os.getenv("USER") or "postgres",
        password = "",
        database = "postgres"
    })
    if not conn then
        print("SKIP: Could not connect to PostgreSQL: " .. tostring(err))
        print("   (PostgreSQL may not be running - this is OK for CI)")
        __lunet_exit_code = 0
        return
    end
    print("   OK: Connection opened")

    local _, rows
    -- Test 2: Create table
    print("2. Creating table...")
    _, err = db.exec(
      conn,
      "CREATE TABLE IF NOT EXISTS smoke_test (id SERIAL PRIMARY KEY, name VARCHAR(255))"
    )
    if err then
        print("FAIL: Could not create table: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Table created")

    -- Test 3: Insert data
    print("3. Inserting data...")
    _, err = db.exec(conn, "INSERT INTO smoke_test (name) VALUES ('hello')")
    if err then
        print("FAIL: Could not insert: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Data inserted")

    -- Test 4: Query data
    print("4. Querying data...")
    rows, err = db.query(conn, "SELECT * FROM smoke_test ORDER BY id DESC LIMIT 1")
    if err then
        print("FAIL: Could not query: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    if #rows ~= 1 or rows[1].name ~= "hello" then
        print("FAIL: Unexpected query result")
        __lunet_exit_code = 1
        return
    end
    print("   OK: Query returned expected data")

    -- Test 5: Clean up
    print("5. Cleaning up...")
    db.exec(conn, "DROP TABLE smoke_test")
    print("   OK: Table dropped")

    -- Test 6: Close connection
    print("6. Closing connection...")
    db.close(conn)
    print("   OK: Connection closed")

    print("")
    print("=== All PostgreSQL tests passed ===")
    __lunet_exit_code = 0
end

lunet.spawn(test_postgres)