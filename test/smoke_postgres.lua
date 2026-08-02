-- Smoke test for PostgreSQL driver
-- Run: ./build/lunet test/smoke_postgres.lua
-- Requires: PostgreSQL running on localhost:5432
-- Env overrides: LUNET_POSTGRES_HOST/PORT/USER/PASSWORD/DATABASE
-- Strictness: LUNET_DB_REQUIRED=1 makes an unreachable server a hard failure

local lunet = require("lunet")
local db = require("lunet.postgres")

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*)[/\\]") or "."
local gate = dofile(script_dir .. "/db_smoke_gate.lua")

local cfg = gate.config("POSTGRES", {
    host = "127.0.0.1",
    port = 5432,
    user = os.getenv("USER") or "postgres",
    password = "",
    database = "postgres"
})

local function test_postgres()
    print("=== PostgreSQL Smoke Test ===")

    -- Test 1: Open connection
    print("1. Opening connection...")
    local conn, err = db.open(cfg)
    if not conn then
        gate.open_failed("PostgreSQL", cfg, err)
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

    -- Test 5: Parameterised queries (item21: exercise query_params/exec_params)
    print("5. Parameterised queries...")
    _, err = db.exec(conn, "CREATE TABLE IF NOT EXISTS smoke_params ("
        .. "id SERIAL PRIMARY KEY, i1 INTEGER, d1 DOUBLE PRECISION, t1 TEXT, b1 BOOLEAN)")
    if err then
        print("FAIL: Could not create params table: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end

    -- 5.1 Single integer parameter
    rows, err = db.query_params(conn,
        "INSERT INTO smoke_params (i1) VALUES ($1) RETURNING id", 42)
    if err or #rows ~= 1 then
        print("FAIL: integer insert errored: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    local id = rows[1].id
    rows, err = db.query_params(conn, "SELECT i1 FROM smoke_params WHERE id = $1", id)
    if err or #rows ~= 1 or rows[1].i1 ~= 42 then
        print("FAIL: integer read-back failed: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: integer parameter")

    -- 5.2 Single string parameter
    rows, err = db.query_params(conn,
        "INSERT INTO smoke_params (t1) VALUES ($1) RETURNING id", "hello")
    if err or #rows ~= 1 then
        print("FAIL: string insert errored: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    id = rows[1].id
    rows, err = db.query_params(conn, "SELECT t1 FROM smoke_params WHERE id = $1", id)
    if err or #rows ~= 1 or rows[1].t1 ~= "hello" then
        print("FAIL: string read-back failed: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: string parameter")

    -- 5.3 NULL parameter
    rows, err = db.query_params(conn,
        "INSERT INTO smoke_params (i1) VALUES ($1) RETURNING id", nil)
    if err or #rows ~= 1 then
        print("FAIL: NULL insert errored: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    id = rows[1].id
    rows, err = db.query_params(conn, "SELECT i1 FROM smoke_params WHERE id = $1", id)
    if err or #rows ~= 1 or rows[1].i1 ~= nil then
        print("FAIL: NULL read-back failed: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    print("   OK: NULL parameter")

    -- 5.4 Boolean parameter (item19e: passed as booleans, not coerced to 1/0)
    for _, b in ipairs({ true, false }) do
        rows, err = db.query_params(conn,
            "INSERT INTO smoke_params (b1) VALUES ($1) RETURNING id", b)
        if err or #rows ~= 1 then
            print("FAIL: boolean insert errored: " .. tostring(err))
            __lunet_exit_code = 1
            return
        end
        id = rows[1].id
        rows, err = db.query_params(conn, "SELECT b1 FROM smoke_params WHERE id = $1", id)
        if err or #rows ~= 1 then
            print("FAIL: boolean read-back failed: " .. tostring(err))
            __lunet_exit_code = 1
            return
        end
        -- Postgres returns booleans as Lua booleans (BOOLOID -> lua_pushboolean)
        local got = rows[1].b1
        if got ~= b then
            print("FAIL: boolean round-trip: sent " .. tostring(b) .. ", got " .. tostring(got))
            __lunet_exit_code = 1
            return
        end
    end
    print("   OK: boolean parameter (item19e)")

    -- 5.5 Multiple parameters (mixed types)
    rows, err = db.query_params(conn,
        "INSERT INTO smoke_params (i1, d1, t1, b1) VALUES ($1, $2, $3, $4) RETURNING id",
        123, 3.14, "mixed", true)
    if err or #rows ~= 1 then
        print("FAIL: mixed insert errored: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    id = rows[1].id
    rows, err = db.query_params(conn,
        "SELECT i1, d1, t1, b1 FROM smoke_params WHERE id = $1", id)
    if err or #rows ~= 1 then
        print("FAIL: mixed read-back failed: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    local r = rows[1]
    if r.i1 ~= 123 or math.abs(r.d1 - 3.14) > 0.001 or r.t1 ~= "mixed" or r.b1 ~= true then
        print("FAIL: mixed parameter round-trip mismatch")
        __lunet_exit_code = 1
        return
    end
    print("   OK: mixed parameters (4 params)")

    -- Clean up params table
    db.exec(conn, "DROP TABLE smoke_params")

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