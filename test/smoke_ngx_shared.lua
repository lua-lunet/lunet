-- Smoke test for lunet.ngx_shared extension
--
-- Before running this test, build the Rust extension:
--   xmake build-ngx-shared
-- Then run via the lunet-shared task:
--   xmake ngx-shared-smoke
-- Or manually:
--   LUNET_NGX_SHARED_LIB=ext/ngx_shared/target/release/libngx_shared.so \
--   lunet-run test/smoke_ngx_shared.lua

-- Add the ext/ngx_shared directory to the Lua module search path so that
-- require("lunet.ngx_shared") resolves the pure-Lua wrapper.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ext_dir = script_dir .. "/../ext/ngx_shared"
package.path = ext_dir .. "/?.lua;" .. package.path
-- Also expose it as lunet.ngx_shared
package.path = ext_dir .. "/?.lua;" ..
               ext_dir .. "/../?/?.lua;" ..
               package.path

-- Teach require("lunet.ngx_shared") to find ext/ngx_shared/ngx_shared.lua
-- by making "lunet.ngx_shared" an alias.
local function load_ngx_shared()
  local full_path = ext_dir .. "/ngx_shared.lua"
  local chunk, err = loadfile(full_path)
  if not chunk then
    error("Cannot load ngx_shared.lua: " .. tostring(err))
  end
  return chunk()
end

local lunet = require("lunet")

local function test_ngx_shared()
  print("=== ngx_shared Smoke Test ===")
  print()

  -- ── Load the module ────────────────────────────────────────────────────────
  print("1. Loading lunet.ngx_shared ...")
  local ok, shared = pcall(load_ngx_shared)
  if not ok then
    print("FAIL: " .. tostring(shared))
    __lunet_exit_code = 1
    return
  end
  print("   OK: module loaded")

  -- ── Open a dictionary ──────────────────────────────────────────────────────
  print("2. Opening dictionary (512 KiB) ...")
  local ok, result = pcall(function() return shared.open("smoke_test", 512 * 1024) end)
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
  local cache2 = shared.open("smoke_test", 512 * 1024)
  cache:set("shared_key", "shared_val")
  local sv = cache2:get("shared_key")
  if sv ~= "shared_val" then
    print("FAIL shared: second handle cannot see value set by first")
    __lunet_exit_code = 1
    return
  end
  print("   OK: both handles see the same data")

  print()
  print("=== All ngx_shared tests passed ===")
  __lunet_exit_code = 0
end

lunet.spawn(test_ngx_shared)
