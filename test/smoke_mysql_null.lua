-- NULL indicator round-trip test for the MySQL driver (item19)
-- Run: ./build/lunet test/smoke_mysql_null.lua
-- Requires: MySQL/MariaDB running on localhost:3306
-- Env overrides: LUNET_MYSQL_HOST/PORT/USER/PASSWORD/DATABASE
-- Strictness: LUNET_DB_REQUIRED=1 makes an unreachable server a hard failure
--
-- Exercises MYSQL_BIND.is_null for every column in both states. Four
-- nullable columns of differing types (INT, DOUBLE, VARCHAR, VARBINARY) in
-- a diagonal NULL pattern: row N has column N NULL and every other column
-- populated, so an indicator read offset by one column produces a
-- detectably wrong pattern. An all-NULL row and an all-populated row cover
-- the extremes. Six rows also force per-row reinitialisation of the
-- indicator arrays across mysql_stmt_fetch calls.
--
-- Assertions run in both directions: NULL columns must come back as Lua
-- nil (and contribute no key), populated columns must come back with their
-- exact inserted value and Lua type. A test checking only the NULLs would
-- pass against an implementation that reported everything as NULL.

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

local COLS = { "c_int", "c_dbl", "c_str", "c_bin" }
local COL_LUA_TYPE = { c_int = "number", c_dbl = "number", c_str = "string", c_bin = "string" }

-- expected[r][c]: false = SQL NULL sentinel (nil would delete the key),
-- otherwise the exact value the column must round-trip to.
-- Binary literals avoid 0x00 bytes: the driver copies column buffers with
-- strdup, so an embedded NUL would truncate (a separate known limitation,
-- out of scope for item19).
local expected = {
    { false, 1.25, "str-1", "\161\11\12\1" },   -- row 1: c_int NULL
    { 1002, false, "str-2", "\162\11\12\2" },   -- row 2: c_dbl NULL
    { 1003, 3.25, false, "\163\11\12\3" },      -- row 3: c_str NULL
    { 1004, 4.25, "str-4", false },             -- row 4: c_bin NULL
    { false, false, false, false },             -- row 5: all NULL
    { 1006, 6.25, "str-6", "\166\11\12\6" },    -- row 6: none NULL
}

local function test_mysql_null()
    print("=== MySQL NULL Indicator Test (item19) ===")

    print("1. Opening connection...")
    local conn, err = db.open(cfg)
    if not conn then
        gate.open_failed("MySQL", cfg, err)
        return
    end
    print("   OK: Connection opened")

    local function fail(msg)
        print("FAIL: " .. msg)
        db.exec(conn, "DROP TABLE IF EXISTS smoke_null_diag")
        db.close(conn)
        __lunet_exit_code = 1
    end

    print("2. Creating table...")
    local _
    _, err = db.exec(conn, "DROP TABLE IF EXISTS smoke_null_diag")
    if err then return fail("Could not drop stale table: " .. tostring(err)) end
    _, err = db.exec(conn,
        "CREATE TABLE smoke_null_diag (" ..
        "id INT AUTO_INCREMENT PRIMARY KEY, " ..
        "c_int INT NULL, " ..
        "c_dbl DOUBLE NULL, " ..
        "c_str VARCHAR(64) NULL, " ..
        "c_bin VARBINARY(16) NULL)")
    if err then return fail("Could not create table: " .. tostring(err)) end
    print("   OK: Table created")

    print("3. Inserting diagonal NULL pattern...")
    _, err = db.exec(conn,
        "INSERT INTO smoke_null_diag (c_int, c_dbl, c_str, c_bin) VALUES " ..
        "(NULL, 1.25, 'str-1', X'A10B0C01'), " ..
        "(1002, NULL, 'str-2', X'A20B0C02'), " ..
        "(1003, 3.25, NULL, X'A30B0C03'), " ..
        "(1004, 4.25, 'str-4', NULL), " ..
        "(NULL, NULL, NULL, NULL), " ..
        "(1006, 6.25, 'str-6', X'A60B0C06')")
    if err then return fail("Could not insert: " .. tostring(err)) end
    print("   OK: 6 rows inserted (4 diagonal + all-NULL + all-populated)")

    print("4. Querying rows back...")
    local rows
    rows, err = db.query(conn,
        "SELECT c_int, c_dbl, c_str, c_bin FROM smoke_null_diag ORDER BY id")
    if err then return fail("Could not query: " .. tostring(err)) end
    if #rows ~= #expected then
        return fail("Expected " .. #expected .. " rows, got " .. #rows)
    end
    print("   OK: Got " .. #rows .. " rows")

    print("5. Verifying NULL/NOT-NULL per column, both directions...")
    for r = 1, #expected do
        local row = rows[r]
        local want_keys = 0
        for c = 1, #COLS do
            local name = COLS[c]
            local exp = expected[r][c]
            local got = row[name]
            if exp == false then
                -- NULL direction: must come back as nil, with no key present
                if got ~= nil then
                    return fail(string.format(
                        "row %d col %s: expected SQL NULL -> Lua nil, got %s (%s)",
                        r, name, tostring(got), type(got)))
                end
            else
                want_keys = want_keys + 1
                -- populated direction: exact value and Lua type
                if type(got) ~= COL_LUA_TYPE[name] then
                    return fail(string.format(
                        "row %d col %s: expected Lua type %s, got %s (%s)",
                        r, name, COL_LUA_TYPE[name], type(got), tostring(got)))
                end
                if got ~= exp then
                    return fail(string.format(
                        "row %d col %s: expected %s, got %s",
                        r, name, tostring(exp), tostring(got)))
                end
            end
        end
        -- A fabricated value for a NULL column (or a vanished populated one)
        -- also shows up as a wrong per-row key count.
        local key_count = 0
        for _ in pairs(row) do key_count = key_count + 1 end
        if key_count ~= want_keys then
            return fail(string.format(
                "row %d: expected %d keys, got %d", r, want_keys, key_count))
        end
    end
    print("   OK: NULL columns are nil, populated columns exact, key counts match")

    print("6. Cleaning up...")
    db.exec(conn, "DROP TABLE smoke_null_diag")
    db.close(conn)
    print("   OK: Table dropped, connection closed")

    print("")
    print("=== All MySQL NULL indicator tests passed ===")
    __lunet_exit_code = 0
end

lunet.spawn(test_mysql_null)
