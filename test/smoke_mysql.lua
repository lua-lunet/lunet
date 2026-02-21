-- Smoke test for MySQL driver
-- Run: ./build/lunet test/smoke_mysql.lua
-- Requires: MySQL/MariaDB running on localhost:3306
-- luacheck: globals __lunet_exit_code

local lunet = require("lunet")
local db = require("lunet.mysql")

local function test_mysql()
    print("=== MySQL Smoke Test ===")

    -- Test 1: Open connection
    print("1. Opening connection...")
    local conn, open_err = db.open({
        host = "127.0.0.1",
        port = 3306,
        user = "root",
        password = "root",
        database = "test"
    })
    if not conn then
        print("SKIP: Could not connect to MySQL: " .. tostring(open_err))
        print("   (MySQL may not be running - this is OK for CI)")
        __lunet_exit_code = 0
        return
    end
    print("   OK: Connection opened")

    -- Test 2: Create table
    print("2. Creating table...")
    local create_sql = "CREATE TABLE IF NOT EXISTS smoke_test " ..
        "(id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))"
    local _, create_err = db.exec(conn, create_sql)
    if create_err then
        print("FAIL: Could not create table: " .. tostring(create_err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Table created")

    -- Test 3: Insert data
    print("3. Inserting data...")
    local _, insert_err = db.exec(conn, "INSERT INTO smoke_test (name) VALUES ('hello')")
    if insert_err then
        print("FAIL: Could not insert: " .. tostring(insert_err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Data inserted")

    -- Test 4: Query data
    print("4. Querying data...")
    local rows, query_err = db.query(conn, "SELECT * FROM smoke_test ORDER BY id DESC LIMIT 1")
    if query_err then
        print("FAIL: Could not query: " .. tostring(query_err))
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
    print("=== All MySQL tests passed ===")
    __lunet_exit_code = 0
end

lunet.spawn(test_mysql)
