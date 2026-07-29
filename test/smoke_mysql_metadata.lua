-- Smoke test for the MySQL result-metadata branch (item19a)
-- Run: ./build/lunet test/smoke_mysql_metadata.lua
-- Requires: MySQL/MariaDB running on localhost:3306
-- Env overrides: LUNET_MYSQL_HOST/PORT/USER/PASSWORD/DATABASE
-- Strictness: LUNET_DB_REQUIRED=1 makes an unreachable server a hard failure
--
-- Under test: the branch in db_query_work_cb (ext/mysql/mysql.c) after
-- mysql_stmt_store_result, where a NULL from mysql_stmt_result_metadata is
-- disambiguated by mysql_stmt_field_count: zero fields means the statement
-- genuinely produced no result set (INSERT/UPDATE/DELETE/DDL) and is a
-- success; a non-zero field count means the metadata call itself failed and
-- is an error.
--
-- Coverage notes (recorded findings, by design):
--
-- (a) The metadata-FAILURE side of the branch (field count > 0 with a NULL
--     metadata handle) is covered by INSPECTION ONLY. Forcing
--     mysql_stmt_result_metadata to fail while the field count stays
--     non-zero requires an out-of-memory condition inside the client
--     library, which is not reachable from this test harness. The risk the
--     branch guards against is a failed SELECT silently surfacing as an
--     empty result set - the opposite misclassification (a no-result-set
--     statement reported as an error) would be loud and is pinned below.
--
-- (b) Affected-rows gap: db.exec/db.exec_params DO report rows changed -
--     their worker calls mysql_stmt_affected_rows directly and this file
--     pins affected_rows == 1 for INSERT/UPDATE/DELETE. The gap is on
--     db.query/db.query_params: db_query_work_cb returns before ever
--     calling mysql_stmt_affected_rows, so a write run through the query
--     path yields a bare empty table with no rows-changed count (pinned in
--     step 4). RECOMMENDATION (not fixed here - it is an API addition
--     needing documentation in the English and Chinese driver docs):
--     either document prominently that writes must go through exec (already
--     the ext/mysql/README.md contract) or surface affected_rows and
--     last_insert_id on the query path's empty result.
--
-- (c) Empty-vs-no-result-set distinguishability: a SELECT matching zero
--     rows and a no-result-set statement BOTH return a bare empty table
--     through db.query/db.query_params (pinned in steps 4 and 5). They are
--     NOT distinguishable by the caller through the query API; the only
--     discriminator is choosing exec for writes, where the shape differs.

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

-- The exec/exec_params no-result-set shape: a table (never nil, never
-- bare) carrying affected_rows and last_insert_id, with an empty array
-- part so #res == 0 and res[1] == nil are safe.
local function expect_exec_shape(label, res, err)
    if not expect(err == nil, label .. " errored: " .. tostring(err)) then
        return false
    end
    if not expect(type(res) == "table", label .. ": first return is "
        .. type(res) .. ", expected table") then
        return false
    end
    expect(#res == 0, label .. ": expected empty array part, #res = " .. #res)
    expect(res[1] == nil, label .. ": res[1] expected nil, got " .. tostring(res[1]))
    expect(type(res.affected_rows) == "number", label
        .. ": affected_rows is " .. type(res.affected_rows) .. ", expected number")
    expect(type(res.last_insert_id) == "number", label
        .. ": last_insert_id is " .. type(res.last_insert_id) .. ", expected number")
    return true
end

-- The query/query_params no-result-set shape (the branch itself): a bare
-- empty table - no rows, no keys at all - and no error.
local function expect_bare_empty(label, rows, err)
    if not expect(err == nil, label .. " errored: " .. tostring(err)) then
        return false
    end
    if not expect(type(rows) == "table", label .. ": first return is "
        .. type(rows) .. ", expected table") then
        return false
    end
    expect(#rows == 0, label .. ": expected 0 rows, got " .. #rows)
    expect(rows[1] == nil, label .. ": rows[1] expected nil, got " .. tostring(rows[1]))
    expect(next(rows) == nil, label .. ": expected no keys at all (bare empty table)")
    return true
end

local function test_mysql_metadata()
    print("=== MySQL Result Metadata Branch Test (item19a) ===")

    print("1. Opening connection...")
    local conn, err = db.open(cfg)
    if not conn then
        gate.open_failed("MySQL", cfg, err)
        return
    end
    print("   OK: Connection opened")

    -- Fresh table every run so repeat runs are idempotent.
    local res, rows
    res, err = db.exec(conn, "DROP TABLE IF EXISTS smoke_meta")
    if not expect_exec_shape("setup DROP", res, err) then
        return
    end
    res, err = db.exec(conn,
        "CREATE TABLE smoke_meta (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(64))")
    if not expect_exec_shape("setup CREATE", res, err) then
        return
    end

    -- 2. No-result-set statements through exec/exec_params. Placeholders fit
    --    INSERT/UPDATE/DELETE, so those run through both; DDL has no
    --    placeholders, so it runs through exec only.
    print("2. No-result-set shape via exec/exec_params (INSERT/UPDATE/DELETE/DDL)...")
    res, err = db.exec(conn, "INSERT INTO smoke_meta (name) VALUES ('m1')")
    if expect_exec_shape("exec INSERT", res, err) then
        expect(res.affected_rows == 1,
            "exec INSERT: affected_rows = " .. tostring(res.affected_rows) .. ", expected 1")
        expect(res.last_insert_id > 0,
            "exec INSERT: expected a positive last_insert_id")
    end
    res, err = db.exec_params(conn, "INSERT INTO smoke_meta (name) VALUES (?)", "m2")
    if expect_exec_shape("exec_params INSERT", res, err) then
        expect(res.affected_rows == 1,
            "exec_params INSERT: affected_rows = " .. tostring(res.affected_rows))
        expect(res.last_insert_id > 0,
            "exec_params INSERT: expected a positive last_insert_id")
    end
    -- UPDATEs always change the value, so affected_rows == 1 holds under
    -- both rows-changed (default) and rows-matched (CLIENT_FOUND_ROWS)
    -- semantics.
    res, err = db.exec(conn, "UPDATE smoke_meta SET name = 'm1x' WHERE name = 'm1'")
    if expect_exec_shape("exec UPDATE", res, err) then
        expect(res.affected_rows == 1,
            "exec UPDATE: affected_rows = " .. tostring(res.affected_rows) .. ", expected 1")
        expect(res.last_insert_id == 0,
            "exec UPDATE: last_insert_id = " .. tostring(res.last_insert_id) .. ", expected 0")
    end
    res, err = db.exec_params(conn,
        "UPDATE smoke_meta SET name = ? WHERE name = ?", "m2x", "m2")
    if expect_exec_shape("exec_params UPDATE", res, err) then
        expect(res.affected_rows == 1,
            "exec_params UPDATE: affected_rows = " .. tostring(res.affected_rows))
    end
    res, err = db.exec(conn, "DELETE FROM smoke_meta WHERE name = 'm1x'")
    if expect_exec_shape("exec DELETE", res, err) then
        expect(res.affected_rows == 1,
            "exec DELETE: affected_rows = " .. tostring(res.affected_rows) .. ", expected 1")
    end
    res, err = db.exec_params(conn, "DELETE FROM smoke_meta WHERE name = ?", "m2x")
    if expect_exec_shape("exec_params DELETE", res, err) then
        expect(res.affected_rows == 1,
            "exec_params DELETE: affected_rows = " .. tostring(res.affected_rows))
    end
    -- DDL (no placeholders -> exec only): a full create/drop cycle.
    res, err = db.exec(conn, "CREATE TABLE smoke_meta_ddl (id INT)")
    if expect_exec_shape("exec DDL CREATE", res, err) then
        expect(res.affected_rows == 0,
            "exec DDL CREATE: affected_rows = " .. tostring(res.affected_rows) .. ", expected 0")
        expect(res.last_insert_id == 0,
            "exec DDL CREATE: last_insert_id = " .. tostring(res.last_insert_id))
    end
    res, err = db.exec(conn, "DROP TABLE smoke_meta_ddl")
    if expect_exec_shape("exec DDL DROP", res, err) then
        expect(res.affected_rows == 0,
            "exec DDL DROP: affected_rows = " .. tostring(res.affected_rows) .. ", expected 0")
    end
    print("   OK: exec/exec_params return {affected_rows, last_insert_id} tables")

    -- 3. The branch itself: no-result-set statements through the query path.
    --    The disambiguation lives in db_query_work_cb, which only db.query /
    --    db.query_params reach; exec uses a different worker. The zero-field
    --    side must be a success returning a bare empty table - and (finding
    --    (b) above) carries no affected_rows count.
    print("3. No-result-set branch via query/query_params...")
    rows, err = db.query(conn, "INSERT INTO smoke_meta (name) VALUES ('q1')")
    expect_bare_empty("query INSERT", rows, err)
    rows, err = db.query_params(conn, "INSERT INTO smoke_meta (name) VALUES (?)", "q2")
    expect_bare_empty("query_params INSERT", rows, err)
    rows, err = db.query(conn, "UPDATE smoke_meta SET name = 'q1x' WHERE name = 'q1'")
    expect_bare_empty("query UPDATE", rows, err)
    print("   OK: query path returns a bare empty table for no-result-set statements")

    -- 4. Result-set side: a SELECT must show that metadata was genuinely
    --    obtained. Column names exist only via the metadata handle, so
    --    named keys on the rows prove the metadata path ran; more than zero
    --    named keys on a row is the observable column count > 0.
    print("4. Result-set side: SELECT carries column metadata...")
    rows, err = db.query(conn, "SELECT id, name FROM smoke_meta ORDER BY id")
    if expect(err == nil and rows ~= nil,
        "metadata SELECT errored: " .. tostring(err)) then
        expect(#rows > 0, "metadata SELECT: expected rows, got " .. #rows)
        if rows[1] ~= nil then
            expect(rows[1].id ~= nil,
                "metadata SELECT: row has no 'id' key (metadata not used?)")
            expect(rows[1].name ~= nil,
                "metadata SELECT: row has no 'name' key (metadata not used?)")
            local nkeys = 0
            for _ in pairs(rows[1]) do
                nkeys = nkeys + 1
            end
            expect(nkeys == 2,
                "metadata SELECT: expected 2 named columns, got " .. nkeys)
        end
    end
    print("   OK: SELECT rows carry column names as keys (metadata handle used)")

    -- 5. Empty-but-valid: a SELECT matching zero rows has metadata and a
    --    field count but no rows. It must return an empty result, not an
    --    error - and through the query API it is NOT distinguishable from
    --    the no-result-set statements of step 3: both are bare empty tables
    --    (finding (c) above, pinned here by comparing the shapes).
    print("5. Empty-but-valid: zero-row SELECT...")
    rows, err = db.query(conn, "SELECT id, name FROM smoke_meta WHERE 1 = 0")
    expect_bare_empty("zero-row SELECT", rows, err)
    local insert_rows
    insert_rows, err = db.query(conn, "INSERT INTO smoke_meta (name) VALUES ('q3')")
    if expect_bare_empty("query INSERT (distinguishability reference)", insert_rows, err) then
        local same_shape = type(rows) == "table" and type(insert_rows) == "table"
            and #rows == 0 and #insert_rows == 0
            and next(rows) == nil and next(insert_rows) == nil
        expect(same_shape,
            "zero-row SELECT and no-result-set INSERT should share the pinned shape")
        -- NOT distinguishable through the query API: the caller cannot tell
        -- "your query matched nothing" from "your statement returns nothing".
    end
    print("   OK: zero-row SELECT is an empty result, not an error"
        .. " (indistinguishable from INSERT via query - recorded finding)")

    if failures > 0 then
        return
    end

    -- 6. Cleanup
    print("6. Cleaning up...")
    db.exec(conn, "DROP TABLE smoke_meta")
    db.close(conn)
    print("   OK: Table dropped, connection closed")

    print("")
    print("=== All MySQL metadata branch tests passed ===")
    __lunet_exit_code = 0
end

lunet.spawn(test_mysql_metadata)
