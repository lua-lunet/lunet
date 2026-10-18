-- Smoke test for SQLite3 driver
-- Run: ./build/lunet test/smoke_sqlite3.lua

local lunet = require("lunet")
local db = require("lunet.sqlite3")

local function test_sqlite3()
    print("=== SQLite3 Smoke Test ===")

    -- Test 1: Open in-memory database (raw: the smoke manages lifetimes)
    print("1. Opening in-memory database...")
    local conn, ro, err = db.open_raw({path = ":memory:"})
    if not conn then
        print("FAIL: Could not open database: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Database opened (one connection returned as rw and ro)")

    local _, rows
    -- Test 2: Create table
    print("2. Creating table...")
    _, err = db.exec(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)")
    if err then
        print("FAIL: Could not create table: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Table created")

    -- Test 3: Insert data
    print("3. Inserting data...")
    _, err = db.exec(conn, "INSERT INTO test (name) VALUES ('hello')")
    if err then
        print("FAIL: Could not insert: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: Data inserted")

    -- Test 4: Query data
    print("4. Querying data...")
    rows, err = db.query(conn, "SELECT * FROM test")
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

    -- Test 4b: the ro handle sees rw's writes — on :memory: both handles
    -- are the same connection (unit-test swap semantics).
    print("4b. Querying through the ro handle...")
    rows, err = db.query(ro, "SELECT * FROM test")
    if err then
        print("FAIL: Could not query via ro: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    if #rows ~= 1 or rows[1].name ~= "hello" then
        print("FAIL: ro handle did not see rw's data")
        __lunet_exit_code = 1
        return
    end
    print("   OK: ro handle sees rw's data")

    -- Test 5: Parameterized query
    print("5. Parameterized query...")
    rows, err = db.query_params(conn, "SELECT * FROM test WHERE name = ?", "hello")
    if err then
        print("FAIL: Could not run parameterized query: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    if #rows ~= 1 then
        print("FAIL: Parameterized query returned wrong count")
        __lunet_exit_code = 1
        return
    end
    print("   OK: Parameterized query works")

    -- Test 6: Close connection
    print("6. Closing connection...")
    db.close(conn)
    db.close(ro)
    print("   OK: Connections closed")

    print("")
    print("=== All SQLite3 tests passed ===")
    __lunet_exit_code = 0
end

lunet.spawn(test_sqlite3)