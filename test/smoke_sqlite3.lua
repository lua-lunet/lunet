-- Smoke test for SQLite3 driver
-- Run: ./build/lunet test/smoke_sqlite3.lua
-- luacheck: globals __lunet_exit_code

local lunet = require("lunet")
local db = require("lunet.sqlite3")

local function test_sqlite3()
    print("=== SQLite3 Smoke Test ===")

    -- Test 1: Open in-memory database
    print("1. Opening in-memory database...")
    local conn, open_err = db.open({path = ":memory:"})
    if not conn then
        print("FAIL: Could not open database: " .. tostring(open_err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Database opened")

    -- Test 2: Create table
    print("2. Creating table...")
    local _, create_err = db.exec(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)")
    if create_err then
        print("FAIL: Could not create table: " .. tostring(create_err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Table created")

    -- Test 3: Insert data
    print("3. Inserting data...")
    local _, insert_err = db.exec(conn, "INSERT INTO test (name) VALUES ('hello')")
    if insert_err then
        print("FAIL: Could not insert: " .. tostring(insert_err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Data inserted")

    -- Test 4: Query data
    print("4. Querying data...")
    local rows, query_err = db.query(conn, "SELECT * FROM test")
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

    -- Test 5: Parameterized query
    print("5. Parameterized query...")
    local param_rows, param_err = db.query_params(conn, "SELECT * FROM test WHERE name = ?", "hello")
    if param_err then
        print("FAIL: Could not run parameterized query: " .. tostring(param_err))
        __lunet_exit_code = 1
        return
    end
    if #param_rows ~= 1 then
        print("FAIL: Parameterized query returned wrong count")
        __lunet_exit_code = 1
        return
    end
    print("   OK: Parameterized query works")

    -- Test 6: Close connection
    print("6. Closing connection...")
    db.close(conn)
    print("   OK: Connection closed")

    print("")
    print("=== All SQLite3 tests passed ===")
    __lunet_exit_code = 0
end

lunet.spawn(test_sqlite3)
