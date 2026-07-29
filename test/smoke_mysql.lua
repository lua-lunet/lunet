-- Smoke test for MySQL driver
-- Run: ./build/lunet test/smoke_mysql.lua
-- Requires: MySQL/MariaDB running on localhost:3306
-- Env overrides: LUNET_MYSQL_HOST/PORT/USER/PASSWORD/DATABASE
-- Strictness: LUNET_DB_REQUIRED=1 makes an unreachable server a hard failure
--
-- Covers both plain db.exec/db.query and the parameterised prepared-statement
-- path (db.exec_params/db.query_params) against a live server: parameter
-- counts 1/2/6, integers at the double exact-representation boundary, doubles,
-- binary strings (empty / high bytes / embedded NUL), NULL via a literal nil
-- argument (verified to reach bind_params - see step 5.1), and the current
-- boolean-coercion contract (see step 5.6).

local lunet = require("lunet")
local db = require("lunet.mysql")

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*)[/\\]") or "."
local gate = dofile(script_dir .. "/db_smoke_gate.lua")

local cfg = gate.config("MYSQL", {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "root",
    database = "test"
})

local failures = 0
local function fail(msg)
    failures = failures + 1
    __lunet_exit_code = 1
    print("FAIL: " .. msg)
end
local function expect(cond, msg)
    if not cond then
        fail(msg)
    end
    return cond
end

local function to_hex(s)
    return (s:gsub(".", function(c)
        return string.format("%02X", c:byte())
    end))
end

local function test_mysql()
    print("=== MySQL Smoke Test ===")

    -- Test 1: Open connection
    print("1. Opening connection...")
    local conn, err = db.open(cfg)
    if not conn then
        gate.open_failed("MySQL", cfg, err)
        return
    end
    print("   OK: Connection opened")

    local _, rows
    -- Test 2: Create table
    print("2. Creating table...")
    _, err = db.exec(
      conn,
      "CREATE TABLE IF NOT EXISTS smoke_test (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))"
    )
    if err then
        fail("Could not create table: " .. tostring(err))
        return
    end
    print("   OK: Table created")

    -- Test 3: Insert data
    print("3. Inserting data...")
    _, err = db.exec(conn, "INSERT INTO smoke_test (name) VALUES ('hello')")
    if err then
        fail("Could not insert: " .. tostring(err))
        return
    end
    print("   OK: Data inserted")

    -- Test 4: Query data
    print("4. Querying data...")
    rows, err = db.query(conn, "SELECT * FROM smoke_test ORDER BY id DESC LIMIT 1")
    if err then
        fail("Could not query: " .. tostring(err))
        return
    end
    if #rows ~= 1 or rows[1].name ~= "hello" then
        fail("Unexpected query result")
        return
    end
    print("   OK: Query returned expected data")

    -- Test 5: Parameterised query path (db.exec_params / db.query_params)
    print("5. Testing parameterised query path...")
    -- Fresh table every run so repeat runs are idempotent even if a previous
    -- run died before cleanup. One column per parameter type under test; the
    -- string columns are VARBINARY so no text collation can mangle bytes.
    _, err = db.exec(conn, "DROP TABLE IF EXISTS smoke_params")
    if err then
        fail("Could not drop smoke_params: " .. tostring(err))
        return
    end
    _, err = db.exec(conn, "CREATE TABLE smoke_params ("
        .. "id INT AUTO_INCREMENT PRIMARY KEY, "
        .. "i1 BIGINT NULL, i2 BIGINT NULL, d1 DOUBLE NULL, "
        .. "s1 VARBINARY(255) NULL, s2 VARBINARY(255) NULL, n1 BIGINT NULL)")
    if err then
        fail("Could not create smoke_params: " .. tostring(err))
        return
    end

    -- 5.1 Establish that a literal nil argument reaches bind_params.
    -- collect_params sizes the param array from lua_gettop(), so an explicit
    -- nil must produce a real SQL NULL here; if it were dropped on the way,
    -- the server-side placeholder would have nothing bound and the driver
    -- would report a parameter count mismatch instead (verified below).
    print("   5.1 nil argument reaches the bind path (PARAM_TYPE_NIL)...")
    rows, err = db.query_params(conn, "SELECT ? AS v", nil)
    if not expect(err == nil and rows ~= nil, "SELECT with nil param errored: " .. tostring(err)) then
        return
    end
    expect(#rows == 1, "SELECT with nil param: expected 1 row, got " .. #rows)
    expect(rows[1] ~= nil and rows[1].v == nil,
        "SELECT with nil param: expected a NULL column (absent key)")
    -- Contrast: omitting the argument entirely must be a count mismatch.
    local no_rows
    no_rows, err = db.query_params(conn, "SELECT ? AS v")
    expect(no_rows == nil and err ~= nil
        and err:find("parameter count mismatch", 1, true) ~= nil,
        "SELECT with a missing param: expected parameter count mismatch, got err="
            .. tostring(err))
    print("   OK: literal nil arrives as a bound SQL NULL parameter")

    -- 5.2 Integer parameters (count 1): negative value and the boundary of
    -- what a double can represent exactly. 2^53 is the last exactly
    -- representable integer; the literal 9007199254740993 (2^53+1) is parsed
    -- by Lua to the same double as 2^53, so the assertion compares against
    -- the Lua value that actually went in. The int/double split happens in C
    -- during collection, so the observable contract is: what comes back
    -- equals what went in.
    print("   5.2 integer round-trip (1 param): negatives and 2^53 boundary...")
    local int_cases = {
        -42,                 -- plain negative
        -9007199254740992,   -- -(2^53)
        9007199254740991,    -- 2^53 - 1
        9007199254740992,    -- 2^53
        9007199254740993,    -- 2^53 + 1: unrepresentable, Lua reads this as 2^53
        9007199254740994,    -- 2^53 + 2
    }
    for _, v in ipairs(int_cases) do
        local res
        res, err = db.exec_params(conn, "INSERT INTO smoke_params (i1) VALUES (?)", v)
        if not expect(err == nil and res ~= nil,
            "int insert " .. tostring(v) .. " errored: " .. tostring(err)) then
            return
        end
        rows, err = db.query_params(conn,
            "SELECT i1 FROM smoke_params WHERE id = ?", res.last_insert_id)
        if not expect(err == nil and rows ~= nil and #rows == 1,
            "int read-back " .. tostring(v) .. " errored: " .. tostring(err)) then
            return
        end
        expect(rows[1].i1 == v,
            "int round-trip: sent " .. tostring(v) .. ", got " .. tostring(rows[1].i1))
    end
    print("   OK: integer parameters round-trip exactly")

    -- 5.3 Double parameters (count 1).
    print("   5.3 double round-trip (1 param)...")
    local dbl_cases = { 0.5, -2.25, 3.141592653589793, 0.1 }
    for _, v in ipairs(dbl_cases) do
        local res
        res, err = db.exec_params(conn, "INSERT INTO smoke_params (d1) VALUES (?)", v)
        if not expect(err == nil and res ~= nil,
            "double insert " .. tostring(v) .. " errored: " .. tostring(err)) then
            return
        end
        rows, err = db.query_params(conn,
            "SELECT d1 FROM smoke_params WHERE id = ?", res.last_insert_id)
        if not expect(err == nil and rows ~= nil and #rows == 1,
            "double read-back " .. tostring(v) .. " errored: " .. tostring(err)) then
            return
        end
        expect(rows[1].d1 == v,
            "double round-trip: sent " .. tostring(v) .. ", got " .. tostring(rows[1].d1))
    end
    print("   OK: double parameters round-trip exactly")

    -- 5.4 String parameters (count 2): empty string and bytes above 0x7F,
    -- byte-exact including length, via binary-safe VARBINARY columns.
    print("   5.4 string round-trip (2 params): empty and high bytes...")
    local high_bytes = string.char(0x80, 0xFF, 0x01, 0xFE) .. "abc"
    local res
    res, err = db.exec_params(conn,
        "INSERT INTO smoke_params (s1, s2) VALUES (?, ?)", "", high_bytes)
    if not expect(err == nil and res ~= nil,
        "string insert errored: " .. tostring(err)) then
        return
    end
    rows, err = db.query_params(conn,
        "SELECT s1, s2 FROM smoke_params WHERE id = ?", res.last_insert_id)
    if not expect(err == nil and rows ~= nil and #rows == 1,
        "string read-back errored: " .. tostring(err)) then
        return
    end
    expect(rows[1].s1 == "" and #rows[1].s1 == 0,
        "empty string round-trip: got " .. tostring(rows[1].s1))
    expect(rows[1].s2 == high_bytes and #rows[1].s2 == #high_bytes,
        "high-byte string round-trip: sent hex " .. to_hex(high_bytes)
            .. ", got hex " .. to_hex(rows[1].s2 or ""))
    print("   OK: string parameters round-trip byte-exactly")

    -- 5.5 String with an embedded NUL. The write bind carries an explicit
    -- buffer_length, so the full payload must reach the server; that is
    -- asserted byte-exactly (including length) via HEX()/LENGTH() read back
    -- through query_params. NOTE: the raw column value itself currently comes
    -- back truncated at the NUL - the result path copies fetched values with
    -- strlen semantics (lunet_strdup_local) and pushes them with
    -- lua_pushstring, ignoring the fetched length. That is a known driver
    -- defect in the shared result-binding path (plain db.query is affected
    -- identically), reported as an item17 finding; the raw-value assertion
    -- below pins the current behaviour and should flip to full byte-equality
    -- once the driver is fixed.
    print("   5.5 embedded NUL (1 param)...")
    local nul_payload = "ab" .. string.char(0x00) .. "cd" .. string.char(0x80, 0xFF)
    res, err = db.exec_params(conn,
        "INSERT INTO smoke_params (s1) VALUES (?)", nul_payload)
    if not expect(err == nil and res ~= nil,
        "NUL-string insert errored: " .. tostring(err)) then
        return
    end
    rows, err = db.query_params(conn,
        "SELECT s1, LENGTH(s1) AS s1_len, HEX(s1) AS s1_hex FROM smoke_params WHERE id = ?",
        res.last_insert_id)
    if not expect(err == nil and rows ~= nil and #rows == 1,
        "NUL-string read-back errored: " .. tostring(err)) then
        return
    end
    expect(rows[1].s1_len == #nul_payload,
        "NUL-string stored length: expected " .. #nul_payload
            .. ", got " .. tostring(rows[1].s1_len))
    expect(rows[1].s1_hex == to_hex(nul_payload),
        "NUL-string stored bytes: expected hex " .. to_hex(nul_payload)
            .. ", got " .. tostring(rows[1].s1_hex))
    -- KNOWN DRIVER DEFECT (item17 finding): read-back truncates at NUL.
    expect(rows[1].s1 == "ab",
        "NUL-string read-back: expected current truncation to 'ab', got hex "
            .. to_hex(rows[1].s1 or ""))
    print("   OK: embedded NUL stored byte-exactly (read-back truncation pinned as known defect)")

    -- 5.6 Boolean parameters. Current contract: collect_params maps
    -- LUA_TBOOLEAN to PARAM_TYPE_INT, so a boolean is silently bound as the
    -- integer 1/0 - no error, no crash. The "unknown parameter type" default
    -- in bind_params is unreachable from Lua; the item17 spec's premise of an
    -- error is outdated. This pins the coercion so a future contract change
    -- (e.g. rejecting booleans) deliberately updates this test.
    print("   5.6 boolean parameters (current coercion contract)...")
    for _, pair in ipairs({ { true, 1 }, { false, 0 } }) do
        local b, expected = pair[1], pair[2]
        res, err = db.exec_params(conn, "INSERT INTO smoke_params (i1) VALUES (?)", b)
        if not expect(err == nil and res ~= nil,
            "boolean insert " .. tostring(b) .. " errored: " .. tostring(err)) then
            return
        end
        rows, err = db.query_params(conn,
            "SELECT i1 FROM smoke_params WHERE id = ?", res.last_insert_id)
        if not expect(err == nil and rows ~= nil and #rows == 1,
            "boolean read-back " .. tostring(b) .. " errored: " .. tostring(err)) then
            return
        end
        expect(rows[1].i1 == expected,
            "boolean round-trip: sent " .. tostring(b) .. ", got " .. tostring(rows[1].i1))
    end
    print("   OK: booleans bind as integers 1/0 (current contract)")

    -- 5.7 Six parameters at once (count 5+): one of each type with a nil
    -- embedded in the middle of the argument list. Also asserts the
    -- exec_params result shape and reads every value back through
    -- query_params, so the parameter path is exercised on write and read.
    print("   5.7 mixed row (6 params, embedded nil)...")
    res, err = db.exec_params(conn,
        "INSERT INTO smoke_params (i1, n1, d1, s1, s2, i2) VALUES (?, ?, ?, ?, ?, ?)",
        -7, nil, -2.5, "x", "y", 9007199254740992)
    if not expect(err == nil and res ~= nil,
        "6-param insert errored: " .. tostring(err)) then
        return
    end
    expect(res.affected_rows == 1,
        "6-param insert: expected affected_rows 1, got " .. tostring(res.affected_rows))
    expect(type(res.last_insert_id) == "number" and res.last_insert_id > 0,
        "6-param insert: expected a positive last_insert_id")
    rows, err = db.query_params(conn,
        "SELECT i1, i2, d1, s1, s2, n1, n1 IS NULL AS n1_isnull"
            .. " FROM smoke_params WHERE id = ?",
        res.last_insert_id)
    if not expect(err == nil and rows ~= nil and #rows == 1,
        "6-param read-back errored: " .. tostring(err)) then
        return
    end
    expect(rows[1].i1 == -7, "6-param row: i1 = " .. tostring(rows[1].i1))
    expect(rows[1].i2 == 9007199254740992, "6-param row: i2 = " .. tostring(rows[1].i2))
    expect(rows[1].d1 == -2.5, "6-param row: d1 = " .. tostring(rows[1].d1))
    expect(rows[1].s1 == "x", "6-param row: s1 = " .. tostring(rows[1].s1))
    expect(rows[1].s2 == "y", "6-param row: s2 = " .. tostring(rows[1].s2))
    expect(rows[1].n1 == nil and rows[1].n1_isnull == 1,
        "6-param row: embedded nil did not arrive as SQL NULL")
    -- Trailing nil in the argument list.
    res, err = db.exec_params(conn,
        "INSERT INTO smoke_params (i1, n1) VALUES (?, ?)", 7, nil)
    if not expect(err == nil and res ~= nil,
        "trailing-nil insert errored: " .. tostring(err)) then
        return
    end
    rows, err = db.query_params(conn,
        "SELECT i1, n1 IS NULL AS n1_isnull FROM smoke_params WHERE id = ?",
        res.last_insert_id)
    if not expect(err == nil and rows ~= nil and #rows == 1,
        "trailing-nil read-back errored: " .. tostring(err)) then
        return
    end
    expect(rows[1].i1 == 7 and rows[1].n1_isnull == 1,
        "trailing nil did not arrive as SQL NULL")
    print("   OK: 6-parameter row round-trips, nil binds as SQL NULL")

    if failures > 0 then
        return
    end
    print("   OK: Parameterised query path passed")

    -- Test 6: Clean up
    print("6. Cleaning up...")
    db.exec(conn, "DROP TABLE smoke_params")
    db.exec(conn, "DROP TABLE smoke_test")
    print("   OK: Tables dropped")

    -- Test 7: Close connection
    print("7. Closing connection...")
    db.close(conn)
    print("   OK: Connection closed")

    print("")
    if failures == 0 then
        print("=== All MySQL tests passed ===")
        __lunet_exit_code = 0
    end
end

lunet.spawn(test_mysql)
