-- Smoke test for MySQL driver
-- Run: ./build/lunet test/smoke_mysql.lua
-- Requires: MySQL/MariaDB running on localhost:3306

local lunet = require("lunet")

-- Resolve the tx wrapper from the source tree, mirroring smoke_postgres.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local wrapper = script_dir .. "/../ext/mysql/mysql_tx.lua"
package.preload["lunet.mysql_tx"] = assert(loadfile(wrapper))

local db = require("lunet.mysql")

local function test_mysql()
    local failures = 0
    local function check(cond, msg)
        if cond then
            print("   OK: " .. msg)
        else
            failures = failures + 1
            print("   FAIL: " .. msg)
        end
        return cond
    end
    print("=== MySQL Smoke Test ===")

    -- Test 1: Open connection
    print("1. Opening connection...")
    local conn, err = db.open({
        host = "127.0.0.1",
        port = 3306,
        user = "root",
        password = "root",
        database = "test",
        charset = "latin1",
        connect_timeout = 10
    })
    if not conn then
        print("SKIP: Could not connect to MySQL: " .. tostring(err))
        print("   (MySQL may not be running - this is OK for CI)")
        __lunet_exit_code = 0
        return
    end
    print("   OK: Connection opened")

    local _, rows
    -- Test 2: Verify the charset passthrough actually took effect on the session
    print("2. Verifying charset passthrough...")
    rows, err = db.query(conn, "SELECT @@character_set_client AS v")
    if err then
        print("FAIL: Could not read character_set_client: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end
    if rows[1].v ~= "latin1" then
        print("FAIL: Expected character_set_client latin1, got " .. tostring(rows[1].v))
        __lunet_exit_code = 1
        return
    end
    print("   OK: charset passthrough in force")

    -- Test 3: Create table
    print("3. Creating table...")
    _, err = db.exec(
      conn,
      "CREATE TABLE IF NOT EXISTS smoke_test (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))"
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
        host = "127.0.0.1", port = 3306,
        user = "root", password = "root", database = "test",
        charset = "latin1", connect_timeout = 10,
        pool_size = 2,
    })
    check(pool and not perr, "pool_size=2 opens")
    if pool then
        local c1, ce1 = db.checkout(pool)
        local c2, ce2 = db.checkout(pool)
        check(c1 and c2 and not ce1 and not ce2, "two checkouts succeed")
        local c3, ce3 = db.checkout(pool)
        check(not c3 and ce3 ~= nil, "third checkout fails loudly (exhausted)")

        -- stickiness: connection id identical across statements on one conn
        -- (MySQL has no BEGIN via prepared statements; use autocommit
        -- discipline as mysql_tx does)
        local r1 = db.query(c1, "SELECT CONNECTION_ID() AS p")
        db.exec(c1, "SET autocommit=0")
        local r2 = db.query(c1, "SELECT CONNECTION_ID() AS p")
        db.exec(c1, "COMMIT")
        db.exec(c1, "SET autocommit=1")
        check(r1 and r2 and r1[1].p == r2[1].p,
              "checked-out conn keeps one connection id across statements")

        -- distinct checkouts get distinct sessions
        local ra = db.query(c1, "SELECT CONNECTION_ID() AS p")
        local rb = db.query(c2, "SELECT CONNECTION_ID() AS p")
        check(ra and rb and ra[1].p ~= rb[1].p, "two checkouts land on different sessions")

        -- ping: liveness through a pool handle and a checked-out member
        local pok, _ = db.ping(pool)
        check(pok == true, "ping through the pool reports alive")
        local pok2, _ = db.ping(c1)
        check(pok2 == true, "ping on a checked-out member reports alive")

        -- prepare works on a checked-out conn
        local stmt, serr = db.prepare(c1, "SELECT ? AS v")
        check(stmt and not serr, "prepare on a checked-out conn works")
        if stmt then
            local q, qe = stmt:query(7)
            check(q and q[1] and q[1].v == 7 and not qe,
                  "prepared stmt runs on the checked-out session")
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

        -- mysql_tx on a checked-out conn commits
        local tx = require("lunet.mysql_tx")
        db.exec(pool, "CREATE TABLE IF NOT EXISTS smoke_chk (v INT)")
        db.exec(pool, "TRUNCATE smoke_chk")
        local c6 = db.checkout(pool)
        local okt, terr = tx.transaction(c6, function(t)
            t.exec("INSERT INTO smoke_chk (v) VALUES (?)", 42)
            return true
        end)
        check(okt and not terr, "mysql_tx commits on a checked-out conn")
        local cnt = db.query(pool, "SELECT COUNT(*) AS n FROM smoke_chk")
        check(cnt and cnt[1] and cnt[1].n == 1, "the committed row is visible through the pool")
        db.release(c6)

        -- pin: a view keeps its pool alive across GC (regression for
        -- the use-after-free where a view outlived its pool userdata)
        do
            local pinned = db.checkout(pool)
            pool = nil -- luacheck: ignore
            collectgarbage(); collectgarbage()
            local r = db.query(pinned, "SELECT CONNECTION_ID() AS p")
            check(r and r[1] and r[1].p, "checked-out conn pins its pool across GC")
            db.release(pinned)
        end
        collectgarbage(); collectgarbage()

        db.exec(conn, "DROP TABLE IF EXISTS smoke_chk")
        print("   OK: Exclusive checkout (transaction stickiness)")
    end

    -- Test 8: Close connection
    print("8. Closing connection...")
    db.close(conn)
    print("   OK: Connection closed")

    print("")
    print(string.format("\n%d failures", failures))
    print("=== All MySQL tests passed ===")
    __lunet_exit_code = (failures == 0) and 0 or 1
end

lunet.spawn(test_mysql)