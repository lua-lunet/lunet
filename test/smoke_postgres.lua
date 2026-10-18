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
        database = "postgres",
        connect_timeout = 10,
        sslmode = "prefer"
    })
    if not conn then
        print("SKIP: Could not connect to PostgreSQL: " .. tostring(err))
        print("   (PostgreSQL may not be running - this is OK for CI)")
        __lunet_exit_code = 0
        return
    end
    print("   OK: Connection opened (connect_timeout + sslmode conninfo accepted)")

    local _, rows
    -- Test 2: Verify a statement works over the passthrough settings
    print("2. Verifying session usable...")
    rows, err = db.query(conn, "SELECT 1 AS one")
    if err then
        print("FAIL: Could not run SELECT 1: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    if rows[1].one ~= 1 then
        print("FAIL: Unexpected SELECT 1 result")
        __lunet_exit_code = 1
        return
    end
    print("   OK: Session usable over passthrough settings")

    -- Test 3: Create table
    print("3. Creating table...")
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

    -- Test 4: Insert data
    print("4. Inserting data...")
    _, err = db.exec(conn, "INSERT INTO smoke_test (name) VALUES ('hello')")
    if err then
        print("FAIL: Could not insert: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Data inserted")

    -- Test 5: Query data
    print("5. Querying data...")
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

    -- Test 6: Clean up
    print("6. Cleaning up...")
    db.exec(conn, "DROP TABLE smoke_test")
    print("   OK: Table dropped")

    -- Test 7: Close connection
    print("7. Closing connection...")
    db.close(conn)
    print("   OK: Connection closed")

    print("")
    print("=== All PostgreSQL tests passed ===")
    __lunet_exit_code = 0
end

lunet.spawn(test_postgres)