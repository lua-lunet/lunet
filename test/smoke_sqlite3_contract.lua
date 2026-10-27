-- Live proof of the sqlite3 ownership contract.
--
-- Run with the runner:
--   LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
--   "$LUNET_BIN" test/smoke_sqlite3_contract.lua
--
-- Sections:
--   1  open contract (missing file / NORMAL / WAL / reopen / passthroughs)
--   2  helper + raw open + mutex modes
--   3  :memory: aliasing through the owner queue
--   4  routing police + read-only rejection
--   5  inline RO without yielding while the worker is busy
--   6  rw suspension, cycles, FIFO order
--   7  named inventory: concurrent same-name callers, distinct results
--   8  errors observable, fail-then-succeed, startup cleanup
--   9  values per cell (NULL/INTEGER/REAL/TEXT/BLOB)
--  10  close: drains accepted work, use-after loud, double close, reopen

local lunet = require("lunet")
local db = require("lunet.sqlite3")

local failures = 0
local checks = 0

local function check(cond, label)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. label)
  else
    print("ok: " .. label)
  end
end

local function rmfile(p)
  os.remove(p); os.remove(p .. "-wal"); os.remove(p .. "-shm"); os.remove(p .. "-journal")
end

-- =========================================================================
-- Section 1: the open contract
-- =========================================================================
local function test_open_contract()
  print("\n=== 1. open contract ===")

  -- 1.1 missing file without create
  local p = ".tmp/contract_1_1.db"
  rmfile(p)
  local rw, ro, err = db.open({ path = p })
  check(rw == nil and ro == nil, "1.1 missing file: no usable pair")
  check(type(err) == "table" and err.message ~= nil, "1.1 missing file: err is a table with message")
  check(type(err) == "table" and err.code ~= nil, "1.1 missing file: err carries the SQLite code")
  check(type(err) == "table" and err.op == "open", "1.1 missing file: op names the operation")

  -- 1.2 create = NORMAL: creates, default journal mode
  p = ".tmp/contract_1_2.db"
  rmfile(p)
  rw, ro, err = db.open({ path = p, create = "NORMAL" })
  check(rw ~= nil and ro ~= nil and not err, "1.2 create=NORMAL opens a pair")
  local mode = db.query_ro(ro, "PRAGMA journal_mode")[1].journal_mode
  check(mode == "delete", "1.2 journal mode untouched at creation (got " .. tostring(mode) .. ")")
  db.close(rw); db.close(ro)
  rmfile(p)

  -- 1.3 create = WAL: requested and verified
  p = ".tmp/contract_1_3.db"
  rmfile(p)
  rw, ro, err = db.open({ path = p, create = "WAL" })
  check(rw ~= nil and not err, "1.3 create=WAL opens")
  check(db.query_ro(ro, "PRAGMA journal_mode")[1].journal_mode == "wal", "1.3 WAL verified")
  db.close(rw); db.close(ro)
  rmfile(p)

  -- 1.4 reopen without create keeps the journal mode
  p = ".tmp/contract_1_4.db"
  rmfile(p)
  rw, ro = db.open({ path = p, create = "WAL" })
  db.close(rw); db.close(ro)
  rw, ro = db.open({ path = p })
  check(rw ~= nil and not err, "1.4 existing file opens without create")
  check(db.query_ro(ro, "PRAGMA journal_mode")[1].journal_mode == "wal", "1.4 journal mode left untouched on reopen")

  -- 1.5 passthroughs
  db.exec(rw, "DROP TABLE IF EXISTS nothing") -- touch rw so both conns are exercised
  db.close(rw)

  local fk_rw, fk_ro, fk_err = db.open({ path = p, foreign_keys = true })
  check(fk_rw ~= nil and not fk_err, "1.5 foreign_keys open")
  check(db.query_ro(fk_ro, "PRAGMA foreign_keys")[1].foreign_keys == 1, "1.5 foreign_keys passthrough applied")
  db.close(fk_rw); db.close(fk_ro)

  local sy_rw, sy_ro, sy_err = db.open({ path = p, synchronous = "FULL" })
  check(sy_rw ~= nil and not sy_err, "1.5 synchronous open")
  check(db.query_ro(sy_ro, "PRAGMA synchronous")[1].synchronous == 2, "1.5 synchronous=FULL applied")
  db.close(sy_rw); db.close(sy_ro)

  local bt_rw, bt_ro, bt_err = db.open({ path = p, busy_timeout = 3000 })
  check(bt_rw ~= nil and not bt_err, "1.5 busy_timeout open")
  -- PRAGMA busy_timeout's readback column is named "timeout" (vendor naming).
  check(db.query_ro(bt_ro, "PRAGMA busy_timeout")[1].timeout == 3000, "1.5 busy_timeout passthrough applied")
  db.close(bt_rw); db.close(bt_ro)
  rmfile(p)

  -- 1.6 unknown option fails loudly
  local ok_guard, guard_err = pcall(function()
    return db.open({ path = ".tmp/never.db", bogus_option = 1 })
  end)
  check(ok_guard == false, "1.6 unknown option errors")
  check(guard_err ~= nil and tostring(guard_err):match("bogus_option") ~= nil,
        "1.6 unknown option names itself")
end

-- =========================================================================
-- Section 2: helper + mutex
-- =========================================================================
local function test_helper_mutex()
  print("\n=== 2. connect helper + mutex ===")

  local p = ".tmp/contract_2.db"
  rmfile(p)

  local rw, ro, err = db.connect(p, { create = "WAL" })
  check(rw ~= nil and not err, "2.1 helper opens")
  check(db.query_ro(ro, "PRAGMA synchronous")[1].synchronous == 1,
        "2.1 helper default is synchronous=NORMAL")
  db.close(rw); db.close(ro)

  rmfile(p)
  rw, ro, err = db.connect(p, { create = "WAL", synchronous = "OFF" })
  check(rw ~= nil and not err, "2.2 helper opens with override")
  check(db.query_ro(ro, "PRAGMA synchronous")[1].synchronous == 0,
        "2.2 explicit caller value wins over the helper default")
  db.close(rw); db.close(ro)

  rmfile(p)
  rw, ro, err = db.open({ path = p, create = "WAL" })
  check(rw ~= nil and not err, "2.3 raw open without synchronous")
  check(db.query_ro(ro, "PRAGMA synchronous")[1].synchronous == 2,
        "2.3 raw open keeps SQLite's compiled default (FULL), not the helper default")
  db.close(rw); db.close(ro)
  rmfile(p)

  rw, ro, err = db.open({ path = p, create = "WAL", mutex = "nomutex" })
  check(rw ~= nil and not err, "2.4 mutex=nomutex accepted")
  db.exec(rw, "CREATE TABLE t (v INTEGER)")
  local rows = db.query_ro(ro, "SELECT COUNT(*) AS n FROM t")
  check(rows ~= nil and rows[1].n == 0, "2.4 nomutex pair usable")
  db.close(rw); db.close(ro)

  rmfile(p)
  rw, ro, err = db.open({ path = p, create = "NORMAL", mutex = "fullmutex" })
  check(rw ~= nil and not err, "2.5 mutex=fullmutex accepted")
  db.close(rw); db.close(ro)
  rmfile(p)

  local ok_guard, guard_err = pcall(function()
    return db.open({ path = ".tmp/never.db", mutex = "SPINLOCK" })
  end)
  check(ok_guard == false, "2.6 invalid mutex value errors")
  check(tostring(guard_err):match("mutex") ~= nil, "2.6 invalid mutex names itself")
end

-- =========================================================================
-- Section 3: :memory: aliasing through the owner queue
-- =========================================================================
local function test_memory_alias()
  print("\n=== 3. :memory: aliasing ===")

  local rw, ro, err = db.open({ path = ":memory:" })
  check(rw ~= nil and ro ~= nil and not err, "3.1 :memory: opens a pair")

  local res, eerr = db.exec(rw, "CREATE TABLE t (v INTEGER)")
  check(res ~= nil and not eerr, "3.1 create via rw")
  local _, ins_err = db.exec(rw, "INSERT INTO t VALUES (7)")
  check(not ins_err, "3.1 insert via rw")

  -- the ro logical path reads through the one physical connection,
  -- serialized by its owner worker
  local rows, qerr = db.query_ro(ro, "SELECT v FROM t")
  check(rows ~= nil and qerr == nil and rows[1].v == 7, "3.2 ro logical path sees rw data (owner-serialized)")

  -- no read-only enforcement on :memory: — a write "via ro" succeeds there
  local _, wmem_err = db.query_ro(ro, "INSERT INTO t VALUES (8)")
  check(not wmem_err, "3.3 write via query_ro on the alias succeeds (documented non-enforcement)")
  rows, eerr = db.query_ro(ro, "SELECT COUNT(*) AS n FROM t")
  check(rows ~= nil and eerr == nil and rows[1].n == 2, "3.3 the alias write landed on the connection")
  db.close(rw)
  db.close(ro)

  -- opening :memory: twice gives two independent private databases
  local a, aro = db.open({ path = ":memory:" })
  local b, bro = db.open({ path = ":memory:" })
  db.exec(a, "CREATE TABLE t (v INTEGER)")
  db.exec(a, "INSERT INTO t VALUES (1)")
  db.exec(b, "CREATE TABLE t (v INTEGER)")
  local n_a = db.query_ro(aro, "SELECT COUNT(*) AS n FROM t")[1].n
  local n_b = db.query_ro(bro, "SELECT COUNT(*) AS n FROM t")[1].n
  check(n_a == 1 and n_b == 0, "3.4 two :memory: opens are isolated private databases")
  db.close(a); db.close(aro); db.close(b); db.close(bro)
end

-- =========================================================================
-- Section 4: routing police + read-only rejection
-- =========================================================================
local function test_routing()
  print("\n=== 4. routing police ===")

  local p = ".tmp/contract_4.db"
  rmfile(p)
  local rw, ro, err = db.open({ path = p, create = "WAL" })
  check(rw ~= nil and not err, "4.1 opens")
  db.exec(rw, "CREATE TABLE t (v INTEGER)")

  local _, eerr = db.query(ro, "SELECT 1")
  check(eerr ~= nil and eerr.op == "route", "4.2 query on the ro handle is a route violation")
  _, eerr = db.query_params(ro, "SELECT 1", { 1 })
  check(eerr ~= nil and eerr.op == "route", "4.3 query_params on the ro handle is a route violation")
  _, eerr = db.exec(ro, "INSERT INTO t VALUES (1)")
  check(eerr ~= nil and eerr.op == "route", "4.4 exec on the ro handle is a route violation")
  _, eerr = db.exec_params(ro, "INSERT INTO t VALUES (?)", { 2 })
  check(eerr ~= nil and eerr.op == "route", "4.5 exec_params on the ro handle is a route violation")
  _, eerr = db.prepare(ro, "SELECT 1")
  check(eerr ~= nil and eerr.op == "route", "4.6 prepare on the ro handle is a route violation")

  -- no silent commits from the rejected routes
  local rows = db.query_ro(ro, "SELECT COUNT(*) AS n FROM t")
  check(rows[1].n == 0, "4.7 the rejected routes committed nothing")

  -- a write sent to the ro connection through query_ro is SQLite's own
  -- read-only rejection
  _, eerr = db.query_ro(ro, "INSERT INTO t VALUES (9)")
  check(eerr ~= nil and eerr.code == 8, "4.8 write via query_ro on file-backed ro: code 8 SQLITE_READONLY")
  check(eerr ~= nil and eerr.extended_code ~= nil, "4.8 extended_code present")
  check(eerr ~= nil and eerr.op == "query_ro", "4.8 op names query_ro")
  rows = db.query_ro(ro, "SELECT COUNT(*) AS n FROM t")
  check(rows[1].n == 0, "4.9 the rejected write committed nothing")
  db.close(rw); db.close(ro)
  rmfile(p)
end

-- =========================================================================
-- Section 5-10 state
-- =========================================================================
local heavy_started = false
local heavy_done = false
local pipe_done = 0
local fifo_done = false
local queue_done = 0
local values_done = false

-- =========================================================================
-- Section 5: inline RO does not wait for the worker
-- =========================================================================
local function test_inline_ro(rw, ro)
  print("\n=== 5. inline RO while the worker runs ===")

  db.exec(rw, "CREATE TABLE big (x)")       -- payload for a slow worker op
  db.exec(rw, "CREATE TABLE small (x)")     -- point-read target
  db.exec(rw, "INSERT INTO small VALUES (1)")
  -- single INSERT generating 400k rows: a real but bounded write
  db.exec(rw, [[INSERT INTO big
                WITH RECURSIVE c(x) AS (VALUES (1) UNION ALL SELECT x+1 FROM c WHERE x < 400000)
                SELECT x FROM c]])

  -- a slow READ on the rw worker (a big scan of the payload)
  lunet.spawn(function()
    heavy_started = true
    local rows, qerr = db.query(rw, [[SELECT COUNT(*)
                                       FROM (WITH RECURSIVE c(x) AS (VALUES (1)
                                            UNION ALL SELECT x+1 FROM c WHERE x < 3000000)
                                             SELECT x FROM c)]])
    if not rows then
      print("FAIL: heavy read failed: " .. (qerr and qerr.message or tostring(qerr)))
    end
    heavy_done = true
  end)

  -- the point read must complete while the heavy read is still running
  lunet.spawn(function()
    lunet.sleep(0.15)  -- give the worker time to be deep inside the heavy read
    local rows, qerr = db.query_ro(ro, "SELECT COUNT(*) AS n FROM small")
    if not rows then
      print("FAIL: point read failed: " .. (qerr and qerr.message or tostring(qerr)))
      heavy_done = true -- unblock the barrier
    else
      check(heavy_started == true and heavy_done == false,
            "5.1 point read completed before the heavy read (worker busy)")
      check(rows[1].n == 1, "5.1 point read returned the right row")
    end
    pipe_done = pipe_done + 1
  end)
end

-- =========================================================================
-- Section 6: rw suspends the caller; FIFO order
-- =========================================================================
local function test_rw_fifo(rw)
  print("\n=== 6. rw suspension + FIFO ===")

  db.exec(rw, "CREATE TABLE fifo (id INTEGER, idx INTEGER)")

  -- suspension proof: the counter coroutine gets cycles while the writer
  -- waits for the worker
  local result, eerr = db.exec(rw, "INSERT INTO fifo VALUES (?, ?)", 0, 0)
  check(result ~= nil and not eerr, "6.1 exec on rw delivers write metadata")

  local cycles = 0
  local stop_cycles = false
  lunet.spawn(function()
    while not stop_cycles do
      cycles = cycles + 1
      lunet.sleep(0.001)
    end
  end)

  local rw_result, rw_err
  lunet.spawn(function()
    rw_result, rw_err = db.exec(rw, "INSERT INTO fifo VALUES (?, ?)", -1, -1)
    stop_cycles = (rw_err == nil)
  end)
  -- wait for the resumed writer coroutine
  for _ = 1, 500 do
    if rw_result then break end
    lunet.sleep(0.002)
  end
  check(rw_result ~= nil and rw_err == nil, "6.2 rw call suspended and resumed")
  check(cycles > 0, "6.2 other coroutines ran while rw was suspended")

  -- FIFO: 12 spawned writers must land in spawn order
  for i = 1, 12 do
    lunet.spawn(function()
      db.exec(rw, "INSERT INTO fifo VALUES (?, ?)", i, i)
      queue_done = queue_done + 1
      if queue_done == 12 then
        local rows, ferr = db.query(rw, "SELECT id, idx FROM fifo WHERE id > 0 ORDER BY rowid")
        if not rows then
          print("FAIL: fifo read failed: " .. (ferr and ferr.message or tostring(ferr)))
        else
          local ordered = true
          local seq = {}
          for k, row in ipairs(rows) do
            seq[#seq + 1] = tostring(row.idx)
            if row.idx ~= k then ordered = false end
          end
          check(ordered, "6.3 twelve spawned writers dispatched in FIFO order")
          if not ordered then
            print("   landed order (by rowid): " .. table.concat(seq, ","))
          end
        end
        fifo_done = true
      end
    end)
  end
end

-- =========================================================================
-- Section 7: the named inventory, concurrent same-name callers
-- =========================================================================
local function test_inventory(rw, ro)
  print("\n=== 7. named inventory ===")

  db.exec(rw, "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)")
  for i = 1, 16 do
    db.exec(rw, "INSERT INTO kv VALUES (?, ?)", i, "val-" .. i)
  end

  local stmt, perr = db.prepare(rw, "SELECT v FROM kv WHERE k = ?")
  check(stmt ~= nil and not perr, "7.1 prepare on the inventory")

  -- 16 concurrent callers of ONE named statement: each gets its own
  -- snapshot's result, in queue order, and nobody sees another's binding.
  local delivered = 0
  local distinct_ok = true
  local distinct_message = nil
  for i = 1, 16 do
    lunet.spawn(function()
      local rows, qerr = stmt:query(i)
      delivered = delivered + 1
      if not rows then
        distinct_ok = false
        distinct_message = qerr and qerr.message or tostring(qerr)
        return
      end
      if rows[1].v ~= "val-" .. i then
        distinct_ok = false
        distinct_message = "caller " .. i .. " got " .. tostring(rows[1].v)
      end
    end)
  end

  for _ = 1, 1000 do
    if delivered == 16 then break end
    lunet.sleep(0.002)
  end
  check(delivered == 16, "7.2 all 16 same-name callers delivered")
  check(distinct_ok, "7.2 distinct correct results for concurrent same-name callers")
  if not distinct_ok and distinct_message then print("   detail: " .. distinct_message) end

  -- errors through the named statement leave it usable
  local bad_rows, bad_err = stmt:query()
  check(bad_rows == nil and bad_err ~= nil, "7.3 wrong parameter count is a result, not a failure")
  local good_rows, good_err = stmt:query(3)
  check(good_err == nil, "7.3 no error on the follow-up call")
  check(good_rows ~= nil and good_rows[1].v == "val-3",
        "7.3 the named statement works right after the failed call")

  -- point reads of the same lines happen inline
  local inline = db.query_ro(ro, "SELECT v FROM kv WHERE k = 5")
  check(inline ~= nil and inline[1].v == "val-5", "7.4 query_ro point read from the ro handle")

  stmt:close()
  check(true, "7.5 stmt:close accepted")
  local closed_rows, closed_err = stmt:query(1)
  check(closed_rows == nil and closed_err ~= nil, "7.5 use after close fails loudly")
end

-- =========================================================================
-- Section 8: errors are results; failed prepare cleanup
-- =========================================================================
local function test_errors(rw, _ro)
  print("\n=== 8. errors ===")

  local _, eerr = db.exec(rw, "SELCT nothing")
  check(eerr ~= nil and eerr.code == 1, "8.1 syntax error: SQLite primary code 1")
  check(eerr ~= nil and eerr.message ~= nil, "8.1 syntax error: message preserved")
  local res2, eerr2 = db.exec(rw, "CREATE TABLE IF NOT EXISTS t8 (v INTEGER)")
  check(res2 ~= nil and not eerr2, "8.2 connection usable after a failed statement")
  local res3 = db.exec(rw, "INSERT INTO t8 VALUES (1)")
  check(res3 ~= nil, "8.2 succeeding call after a failed one works")

  -- failed prepare cleans up
  local stmt, perr = db.prepare(rw, "SELECT nope FROM nowhere")
  check(stmt == nil and perr ~= nil, "8.3 failed prepare is (nil, err)")
  check(perr.op == "prepare" and perr.code ~= nil, "8.3 failed prepare carries context")
  local rw2, ro2, oerr2 = db.open({ path = ".tmp/contract_8.db", create = "WAL" })
  check(rw2 ~= nil and not oerr2, "8.3 connection still opens after a failed prepare")
  local stmt2, perr2 = db.prepare(rw2, "SELECT 1")
  check(stmt2 ~= nil and not perr2, "8.4 prepare works on the fresh connection")
  stmt2:close()
  db.close(rw2); db.close(ro2)
  rmfile(".tmp/contract_8.db")
end

-- =========================================================================
-- Section 9: values per cell
-- =========================================================================
local function test_values(rw, ro)
  print("\n=== 9. values ===")

  db.exec(rw, "CREATE TABLE vals (a, b, c, d, e)")
  db.exec(rw, "INSERT INTO vals VALUES (NULL, 42, 3.25, 'txt', x'410042')")

  local rows, qerr = db.query_ro(ro, "SELECT a, b, c, d, e FROM vals")
  if not rows then
    print("FAIL: value read failed: " .. (qerr and qerr.message or tostring(qerr)))
  else
    local row = rows[1]
    check(row.a == nil, "9.1 NULL reads as nil")
    check(row.b == 42, "9.2 integer reads as integer")
    check(row.c == 3.25, "9.3 real reads as real")
    check(row.d == "txt", "9.4 text reads as text")
    check(type(row.e) == "string" and #row.e == 3, "9.5 blob reads with exact length")
    check(type(row.e) == "string" and row.e:byte(1) == 65 and row.e:byte(2) == 0 and row.e:byte(3) == 66,
          "9.5 blob bytes preserved including the embedded NUL")
  end
  values_done = true
end

-- =========================================================================
-- Section 10: close drains the accepted work
-- =========================================================================
local function test_close_drain(rw, ro)
  print("\n=== 10. close drains ===")

  -- accepted-but-not-finished rw work: close must wait for it to drain
  local heavy_finished_by_close = nil
  db.exec(rw, "CREATE TABLE drain (x)")
  db.exec(rw, [[INSERT INTO drain
                WITH RECURSIVE c(x) AS (VALUES (1) UNION ALL SELECT x+1 FROM c WHERE x < 300000)
                SELECT x FROM c]])
  lunet.spawn(function()
    local rows, qerr = db.query(rw, "SELECT COUNT(*) AS n FROM drain")
    if rows then
      check(rows[1].n == 300000, "10.1 accepted rw op delivered before close finishes")
      heavy_finished_by_close = true
    else
      heavy_finished_by_close = false
      print("FAIL: drain op failed: " .. (qerr and qerr.message or tostring(qerr)))
    end
  end)

  -- close queues behind everything accepted: the result arrives first
  db.close(rw)
  check(heavy_finished_by_close == true, "10.2 close waited for accepted work to drain")

  -- use after close fails loudly
  local _, eerr = db.exec(rw, "INSERT INTO drain VALUES (1)")
  check(eerr ~= nil, "10.3 use after close fails loudly")
  -- the ro handle is an independent connection: it still reads until
  -- closed per-handle
  local ro_rows, ro_err = db.query_ro(ro, "SELECT COUNT(*) AS n FROM drain")
  check(ro_rows ~= nil and ro_err == nil and ro_rows[1].n == 300000,
        "10.4 the ro handle still reads until closed per-handle")
  db.close(ro)
  _, eerr = db.query_ro(ro, "SELECT 1")
  check(eerr ~= nil, "10.4 after ro close, use fails loudly")

  -- ro close then use
  local rw5, ro5 = db.open({ path = ".tmp/contract_10b.db", create = "WAL" })
  db.exec(rw5, "CREATE TABLE t (v)")
  db.close(ro5)
  local _, reuse_err = db.query_ro(ro5, "SELECT 1")
  check(reuse_err ~= nil, "10.5 use after ro close fails loudly")
  -- double close is a no-op; reopen works
  db.close(rw5)
  local res = db.close(rw5)
  check(res == nil, "10.6 double close is a no-op")
  rmfile(".tmp/contract_10b.db")

  local rw6, ro6, oerr6 = db.open({ path = ".tmp/contract_10c.db", create = "WAL" })
  check(rw6 ~= nil and not oerr6, "10.7 reopen after close works")
  db.close(rw6); db.close(ro6)
  rmfile(".tmp/contract_10c.db")
end

-- =========================================================================
-- Driver
-- =========================================================================
local function main()
  local p = ".tmp/contract_main.db"
  rmfile(p)

  test_open_contract()
  test_helper_mutex()
  test_memory_alias()
  test_routing()

  local rw, ro, err = db.open({ path = p, create = "WAL" })
  if not rw then
    print("FAIL: main db open: " .. (err and err.message or tostring(err)))
    __lunet_exit_code = 1
    return
  end

  test_inline_ro(rw, ro)
  test_rw_fifo(rw)
  test_inventory(rw, ro)
  test_errors(rw, ro)
  test_values(rw, ro)

  for _ = 1, 20000 do
    if pipe_done == 1 and fifo_done and values_done then break end
    lunet.sleep(0.002)
  end
  check(pipe_done == 1, "barrier: inline-ro section completed")
  check(fifo_done, "barrier: fifo section completed")
  check(values_done, "barrier: values section completed")

  test_close_drain(rw, ro)

  db.close(ro)
  rmfile(p)
  rmfile(".tmp/contract_4.db")
  rmfile(".tmp/contract_main.db")

  print("\n=== " .. (failures == 0
        and ("ALL CONTRACT CHECKS PASSED (" .. checks .. " checks) ===")
        or (failures .. " of " .. checks .. " checks FAILED ===")))
  __lunet_exit_code = (failures == 0) and 0 or 1
end

-- The close-drain section closes its own handles; failures in earlier
-- sections must not skip the barrier cleanup. Standard exit code path.
lunet.spawn(main)
