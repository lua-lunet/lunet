-- Smoke test for lunet.lnt_shared extension
--
-- Before running this test, build the Rust extension:
--   xmake build-lnt-shared
-- Then run via the lunet-shared task:
--   xmake lnt-shared-smoke
-- Or manually:
--   LUNET_LNT_SHARED_LIB=ext/lnt_shared/target/release/liblnt_shared.so \
--   lunet-run test/smoke_lnt_shared.lua

-- Add the ext/lnt_shared directory to the Lua module search path so that
-- require("lunet.lnt_shared") resolves the pure-Lua wrapper.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ext_dir = script_dir .. "/../ext/lnt_shared"
package.path = ext_dir .. "/?.lua;" .. package.path
-- Also expose it as lunet.lnt_shared
package.path = ext_dir .. "/?.lua;" ..
               ext_dir .. "/../?/?.lua;" ..
               package.path

-- Teach require("lunet.lnt_shared") to find ext/lnt_shared/lnt_shared.lua
-- by making "lunet.lnt_shared" an alias.
local function load_lnt_shared()
  local full_path = ext_dir .. "/lnt_shared.lua"
  local chunk, err = loadfile(full_path)
  if not chunk then
    error("Cannot load lnt_shared.lua: " .. tostring(err))
  end
  return chunk()
end

local lunet = require("lunet")

local function test_lnt_shared()
  print("=== lnt_shared Smoke Test ===")
  print()

  -- ── Load the module ────────────────────────────────────────────────────────
  print("1. Loading lunet.lnt_shared ...")
  local ok, lnt = pcall(load_lnt_shared)
  if not ok then
    print("FAIL: " .. tostring(lnt))
    __lunet_exit_code = 1
    return
  end
  print("   OK: module loaded")

  -- ── Open a dictionary ──────────────────────────────────────────────────────
  print("2. Opening dictionary (512 KiB) ...")
  local ok, result = pcall(function() return lnt.store("smoke_test", 512 * 1024) end)
  if not ok then
    print("FAIL: " .. tostring(result))
    __lunet_exit_code = 1
    return
  end
  local cache = result
  print("   OK: capacity=" .. tostring(cache:capacity()) .. " bytes")

  -- ── Flush to start clean ───────────────────────────────────────────────────
  cache:flush_all()

  -- ── set / get string ──────────────────────────────────────────────────────
  print("3. set/get string ...")
  local r, e = cache:set("greeting", "hello")
  if not r then
    print("FAIL set: " .. tostring(e))
    __lunet_exit_code = 1
    return
  end
  local v, ve = cache:get("greeting")
  if v ~= "hello" then
    print("FAIL get string: expected 'hello', got " .. tostring(v) .. " err=" .. tostring(ve))
    __lunet_exit_code = 1
    return
  end
  print("   OK: got '" .. v .. "'")

  -- ── set / get number ──────────────────────────────────────────────────────
  print("4. set/get number ...")
  cache:set("pi", 3.14159)
  local n = cache:get("pi")
  if type(n) ~= "number" or math.abs(n - 3.14159) > 1e-9 then
    print("FAIL get number: got " .. tostring(n))
    __lunet_exit_code = 1
    return
  end
  print("   OK: got " .. tostring(n))

  -- ── set / get boolean ─────────────────────────────────────────────────────
  print("5. set/get boolean ...")
  cache:set("flag", true)
  local b = cache:get("flag")
  if b ~= true then
    print("FAIL get bool: got " .. tostring(b))
    __lunet_exit_code = 1
    return
  end
  print("   OK: got " .. tostring(b))

  -- ── add (key absent) ──────────────────────────────────────────────────────
  print("6. add (key absent) ...")
  local a_ok, a_err = cache:add("newkey", "newval")
  if not a_ok then
    print("FAIL add: " .. tostring(a_err))
    __lunet_exit_code = 1
    return
  end
  print("   OK: added newkey")

  -- ── add (key present) ─────────────────────────────────────────────────────
  print("7. add (key present — should fail with 'already exists') ...")
  local a2_ok, a2_err = cache:add("greeting", "dup")
  if a2_ok then
    print("FAIL: add should have returned nil,err for existing key")
    __lunet_exit_code = 1
    return
  end
  if a2_err ~= "already exists" then
    print("FAIL: expected 'already exists', got '" .. tostring(a2_err) .. "'")
    __lunet_exit_code = 1
    return
  end
  print("   OK: correctly rejected duplicate add")

  -- ── replace ───────────────────────────────────────────────────────────────
  print("8. replace ...")
  local rp_ok, rp_err = cache:replace("greeting", "world")
  if not rp_ok then
    print("FAIL replace: " .. tostring(rp_err))
    __lunet_exit_code = 1
    return
  end
  if cache:get("greeting") ~= "world" then
    print("FAIL replace: value not updated")
    __lunet_exit_code = 1
    return
  end
  print("   OK: greeting is now 'world'")

  -- ── incr ──────────────────────────────────────────────────────────────────
  print("9. incr (new key with init=0) ...")
  local cnt, incr_err = cache:incr("counter", 1, 0)
  if not cnt then
    print("FAIL incr: " .. tostring(incr_err))
    __lunet_exit_code = 1
    return
  end
  if cnt ~= 1 then
    print("FAIL incr: expected 1, got " .. tostring(cnt))
    __lunet_exit_code = 1
    return
  end
  cache:incr("counter", 5)
  local cnt2 = cache:get("counter")
  if cnt2 ~= 6 then
    print("FAIL incr: expected 6, got " .. tostring(cnt2))
    __lunet_exit_code = 1
    return
  end
  print("   OK: counter=" .. tostring(cnt2))

  -- ── delete ────────────────────────────────────────────────────────────────
  print("10. delete ...")
  cache:delete("newkey")
  local dv, de = cache:get("newkey")
  if dv ~= nil then
    print("FAIL delete: key still present")
    __lunet_exit_code = 1
    return
  end
  if de ~= "not found" then
    print("FAIL delete: expected 'not found', got '" .. tostring(de) .. "'")
    __lunet_exit_code = 1
    return
  end
  print("   OK: newkey deleted")

  -- ── ttl / expire ──────────────────────────────────────────────────────────
  print("11. TTL management ...")
  -- Set with TTL=10s; remaining TTL should be in (0, 10].
  cache:set("ephemeral", "bye", 10)
  local t, terr = cache:ttl("ephemeral")
  if not t then
    print("FAIL ttl: " .. tostring(terr))
    __lunet_exit_code = 1
    return
  end
  if t <= 0 or t > 10 then
    print("FAIL ttl: expected (0,10], got " .. tostring(t))
    __lunet_exit_code = 1
    return
  end
  print("   OK: remaining TTL = " .. string.format("%.2f", t) .. "s")

  -- expire() to remove TTL
  cache:expire("ephemeral", 0)
  local t2 = cache:ttl("ephemeral")
  if t2 ~= -1 then
    print("FAIL expire: expected -1 (no expiry), got " .. tostring(t2))
    __lunet_exit_code = 1
    return
  end
  print("   OK: TTL removed (ttl=-1)")

  -- ── flush_all ─────────────────────────────────────────────────────────────
  print("12. flush_all ...")
  cache:flush_all()
  local fv = cache:get("greeting")
  if fv ~= nil then
    print("FAIL flush_all: greeting still present after flush")
    __lunet_exit_code = 1
    return
  end
  print("   OK: all entries cleared")

  -- ── capacity / free_space ─────────────────────────────────────────────────
  print("13. capacity / free_space ...")
  local cap = cache:capacity()
  local free = cache:free_space()
  if type(cap) ~= "number" or cap <= 0 then
    print("FAIL capacity: " .. tostring(cap))
    __lunet_exit_code = 1
    return
  end
  if type(free) ~= "number" or free <= 0 or free > cap then
    print("FAIL free_space: " .. tostring(free))
    __lunet_exit_code = 1
    return
  end
  print(string.format("   OK: capacity=%d free=%d", cap, free))

  -- ── Shared-handle semantics: second open returns same region ───────────────
  print("14. Shared handle (same name = same region) ...")
  local cache2 = lnt.store("smoke_test", 512 * 1024)
  cache:set("shared_key", "shared_val")
  local sv = cache2:get("shared_key")
  if sv ~= "shared_val" then
    print("FAIL shared: second handle cannot see value set by first")
    __lunet_exit_code = 1
    return
  end
  print("   OK: both handles see the same data")

  -- Compact assertion helpers for the extended cases.
  local step = 14
  local function fail(msg)
    print("FAIL: " .. msg)
    __lunet_exit_code = 1
    error("__smoke_abort__", 0)
  end
  local function ok(msg)
    step = step + 1
    print(("   OK (%d): %s"):format(step, msg))
  end
  local function check(cond, msg)
    if not cond then fail(msg) end
  end
  local aborted = select(2, pcall(function()

  -- ── Missing-key error contracts ────────────────────────────────────────────
  local v, e = cache:get("never_set")
  check(v == nil and e == "not found", "get missing: want nil,'not found', got " .. tostring(v) .. "," .. tostring(e))
  ok("get missing key -> nil, 'not found'")

  local d_ok, d_err = cache:delete("never_set")
  check(d_ok == nil and d_err == "not found", "delete missing should fail with 'not found'")
  ok("delete missing key -> nil, 'not found'")

  local r_ok, r_err = cache:replace("never_set", "x")
  check(r_ok == nil and r_err == "not found", "replace missing should fail with 'not found'")
  ok("replace missing key -> nil, 'not found'")

  local x_ok, x_err = cache:expire("never_set", 5)
  check(x_ok == nil and x_err == "not found", "expire missing should fail with 'not found'")
  ok("expire missing key -> nil, 'not found'")

  local t_ok, t_err = cache:ttl("never_set")
  check(t_ok == nil and t_err == "not found", "ttl missing should fail with 'not found'")
  ok("ttl missing key -> nil, 'not found'")

  -- ── Type errors ────────────────────────────────────────────────────────────
  cache:set("str_for_incr", "not_a_number")
  local i_ok, i_err = cache:incr("str_for_incr", 1)
  check(i_ok == nil and i_err == "type mismatch", "incr on string should fail with 'type mismatch', got " .. tostring(i_err))
  ok("incr on string -> nil, 'type mismatch'")

  local set_ok, set_err = pcall(function() cache:set("bad", { 1 }) end)
  check(not set_ok, "set with table value should raise an error")
  ok("set table value -> Lua error raised")

  -- ── Value type round-trips ─────────────────────────────────────────────────
  cache:set("bool_false", false)
  check(cache:get("bool_false") == false, "boolean false round-trip failed")
  ok("boolean false round-trip")

  cache:set("neg_float", -1234.5)
  local nf = cache:get("neg_float")
  check(type(nf) == "number" and math.abs(nf - (-1234.5)) < 1e-9, "negative float round-trip failed")
  ok("negative float round-trip")

  cache:set("empty_str", "")
  check(cache:get("empty_str") == "", "empty string round-trip failed")
  ok("empty string round-trip")

  cache:set("a\0b", "nul_key")
  check(cache:get("a\0b") == "nul_key", "binary key with NUL byte failed")
  ok("binary key with embedded NUL")

  local big = string.rep("z", 64 * 1024)
  cache:set("big_val", big)
  check(cache:get("big_val") == big, "64 KiB value round-trip failed")
  ok("64 KiB value round-trip")

  -- ── incr variants ──────────────────────────────────────────────────────────
  cache:flush_all()
  local dv = cache:incr("ctr_default", nil, 0) -- delta omitted -> 1
  check(dv == 1, "incr with default delta should give 1, got " .. tostring(dv))
  ok("incr default delta = 1")

  local noinit_ok, noinit_err = cache:incr("no_such", 1)
  check(noinit_ok == nil and noinit_err == "not found", "incr without init on missing key should fail with 'not found'")
  ok("incr missing key without init -> nil, 'not found'")

  -- ── Real TTL expiry end-to-end ─────────────────────────────────────────────
  -- NB: lunet.sleep takes MILLISECONDS; dict TTLs are in seconds.
  cache:set("will_expire", "gone_soon", 0.05)
  lunet.sleep(100) -- 100 ms > 50 ms TTL
  local evicted = cache:flush_expired()
  check(evicted >= 1, "flush_expired should evict >= 1, got " .. tostring(evicted))
  local gone = cache:get("will_expire")
  check(gone == nil, "expired key should be absent after flush_expired")
  ok("flush_expired evicts real expired entries (" .. tostring(evicted) .. ")")

  cache:set("ttl_a", "x", 0.05)
  cache:set("ttl_b", "x", 0.05)
  cache:set("ttl_c", "x", 0.05)
  lunet.sleep(100)
  local ev1 = cache:flush_expired(2) -- max = 2
  check(ev1 == 2, "flush_expired(max=2) should evict exactly 2, got " .. tostring(ev1))
  ok("flush_expired honours max limit")

  -- ── add with TTL ───────────────────────────────────────────────────────────
  local a_ok = cache:add("temp_add", "v", 30)
  check(a_ok == true, "add with TTL failed")
  local at = cache:ttl("temp_add")
  check(type(at) == "number" and at > 0 and at <= 30, "add TTL should be in (0,30], got " .. tostring(at))
  ok("add with TTL sets expiry")

  -- ── tostring ───────────────────────────────────────────────────────────────
  check(tostring(cache):find("smoke_test", 1, true) ~= nil, "tostring should include dict name")
  ok("tostring includes dict name")

  -- ── close() lifecycle ──────────────────────────────────────────────────────
  local tmp = lnt.store("smoke_close", 65536)
  tmp:set("k", "v")
  check(tmp:close() == true, "close() should return true")
  check(tmp:close() == true, "second close() should be a safe no-op returning true")
  local cv, cerr = tmp:get("k")
  check(cv == nil and cerr == "not found", "get after close should fail gracefully, got " .. tostring(cv) .. "," .. tostring(cerr))
  ok("close() + double-close + use-after-close is safe")

  -- A fresh handle to the same region still sees old data (region outlives
  -- individual handles).
  local tmp2 = lnt.store("smoke_close", 65536)
  check(tmp2:get("k") == "v", "region should outlive a closed handle")
  ok("region persists after single handle close")

  end)) -- end of protected extended block
  if aborted ~= "__smoke_abort__" and aborted ~= nil then
    -- An unexpected Lua error inside the extended block.
    print("FAIL (unexpected): " .. tostring(aborted))
    __lunet_exit_code = 1
  end
  if __lunet_exit_code ~= 1 then
    print()
    print("=== All lnt_shared tests passed (" .. step .. " checks) ===")
    __lunet_exit_code = 0
  end
end

lunet.spawn(test_lnt_shared)
