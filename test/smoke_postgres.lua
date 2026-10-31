-- Smoke test for PostgreSQL driver
-- Run: ./build/lunet test/smoke_postgres.lua
-- Requires: PostgreSQL running on localhost:5432

local lunet = require("lunet")

-- Resolve the tx wrapper from the source tree, mirroring smoke_postgres_tx.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local wrapper = script_dir .. "/../ext/postgres/postgres_tx.lua"
package.preload["lunet.postgres_tx"] = assert(loadfile(wrapper))

local db = require("lunet.postgres")

local function test_postgres()
    local failures = 0
    local function check(cond, msg)
        if cond then
            print("   OK: " .. msg)
        else
            failures = failures + 1
            print("   FAIL: " .. msg)
            __lunet_exit_code = 1
        end
    end
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

    -- Test 7: Exclusive checkout (transaction stickiness)
    print("7. Exclusive checkout (transaction stickiness)...")
    local pool, perr = db.open({
        host = "127.0.0.1", port = 5432,
        user = os.getenv("USER") or "postgres",
        password = "", database = "postgres",
        connect_timeout = 10, sslmode = "prefer",
        pool_size = 2,
    })
    check(pool and not perr, "pool_size=2 opens")
    if pool then
        local c1, ce1 = db.checkout(pool)
        local c2, ce2 = db.checkout(pool)
        check(c1 and c2 and not ce1 and not ce2, "two checkouts succeed")
        local c3, ce3 = db.checkout(pool)
        check(not c3 and ce3 ~= nil, "third checkout fails loudly (exhausted)")

        -- stickiness: backend pid identical across BEGIN..COMMIT on one conn
        local r1 = db.query(c1, "SELECT pg_backend_pid() AS p")
        db.exec(c1, "BEGIN")
        local r2 = db.query(c1, "SELECT pg_backend_pid() AS p")
        db.exec(c1, "COMMIT")
        check(r1 and r2 and r1[1].p == r2[1].p, "checked-out conn keeps one backend pid across statements")

        -- distinct checkouts get distinct sessions
        local ra = db.query(c1, "SELECT pg_backend_pid() AS p")
        local rb = db.query(c2, "SELECT pg_backend_pid() AS p")
        check(ra and rb and ra[1].p ~= rb[1].p, "two checkouts land on different sessions")

        -- prepare works on a checked-out conn
        local stmt, serr = db.prepare(c1, "SELECT $1::int AS v")
        check(stmt and not serr, "prepare on a checked-out conn works")
        if stmt then
            local q, qe = stmt:query(7)
            check(q and q[1] and q[1].v == 7 and not qe, "prepared stmt runs on the checked-out session")
            stmt:close()
        end

        -- release restores the rotation
        check(db.release(c1) == nil, "release succeeds")
        check(db.release(c2) == nil, "release succeeds")
        local c4, ce4 = db.checkout(pool)
        check(c4 and not ce4, "after release a new checkout succeeds")

        -- double release fails loudly
        db.release(c4)
        local _, dre = db.release(c4)
        check(dre ~= nil, "double release fails loudly")

        -- GC release: drop a checkout, collect, then a fresh checkout works
        do
            local doomed = db.checkout(pool)
            assert(doomed)
        end
        collectgarbage(); collectgarbage()
        local c5, ce5 = db.checkout(pool)
        check(c5 and not ce5, "GC releases a dropped checkout")
        db.release(c5)

        -- postgres_tx on a checked-out conn commits
        local tx = require("lunet.postgres_tx")
        db.exec(pool, "CREATE TABLE IF NOT EXISTS smoke_chk (v INTEGER)")
        db.exec(pool, "TRUNCATE smoke_chk")
        local c6 = db.checkout(pool)
        local okt, terr = tx.transaction(c6, function(t)
            t.exec("INSERT INTO smoke_chk (v) VALUES ($1)", 42)
            return true
        end)
        check(okt and not terr, "postgres_tx commits on a checked-out conn")
        local cnt = db.query(pool, "SELECT COUNT(*) AS n FROM smoke_chk")
        check(cnt and cnt[1] and cnt[1].n == 1, "the committed row is visible through the pool")
        db.release(c6)

        -- pin: a view keeps its pool alive across GC (regression for
        -- the use-after-free where a view outlived its pool userdata)
        do
            local pinned = db.checkout(pool)
            pool = nil -- luacheck: ignore
            collectgarbage(); collectgarbage()
            local r = db.query(pinned, "SELECT pg_backend_pid() AS p")
            check(r and r[1] and r[1].p, "checked-out conn pins its pool across GC")
            db.release(pinned)
        end
        collectgarbage(); collectgarbage()

        print("   OK: Exclusive checkout (transaction stickiness)")
    end

    -- Test 8: Close connection
    print("8. Closing connection...")
    db.close(conn)
    print("   OK: Connection closed")

    print("")
    print(string.format("\n%d failures", failures))
    print("=== PostgreSQL smoke complete ===")
    __lunet_exit_code = (failures == 0) and 0 or 1
end

lunet.spawn(test_postgres)