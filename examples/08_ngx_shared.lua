--[[
ngx_shared Extension Demo for lunet

This demo shows how to use the lunet.ngx_shared extension — an nginx-style
shared dictionary backed by a Rust FFI library.

NOTE: This is NOT a dependency on nginx or OpenResty.  The API is inspired
by ngx.shared.DICT for convenience, but this is an independent implementation.
Undefined or implementation-specific OpenResty behaviour is explicitly NOT
replicated.

Prerequisites
  1. Build the Rust extension once:
       cd ext/ngx_shared && cargo build --release
     Or via xmake:
       xmake build-ngx-shared

  2. Run this example:
       LUNET_NGX_SHARED_LIB=ext/ngx_shared/target/release/libngx_shared.so \
       ./build/linux/x86_64/release/lunet-run examples/08_ngx_shared.lua
     Or via xmake:
       xmake ngx-shared-smoke  (runs smoke_ngx_shared.lua, not this file)
]]

-- Load the Lua wrapper from the extension directory.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ext_lua = script_dir .. "/../ext/ngx_shared/ngx_shared.lua"
local chunk, err = loadfile(ext_lua)
if not chunk then
  error("Cannot find ngx_shared.lua: " .. tostring(err) ..
        "\nBuild with: cd ext/ngx_shared && cargo build --release")
end
local shared = chunk()

local lunet = require("lunet")

lunet.spawn(function()
  print("=== lunet.ngx_shared Demo ===")
  print()

  -- ── Open a 1 MiB dictionary ────────────────────────────────────────────────
  local cache = shared.open("demo_cache", 1024 * 1024)
  cache:flush_all()  -- start clean

  print(string.format("Dictionary capacity : %d bytes", cache:capacity()))
  print(string.format("Free space initially: %d bytes", cache:free_space()))
  print()

  -- ── Basic string storage ───────────────────────────────────────────────────
  print("-- String storage --")
  cache:set("user:1:name", "Alice")
  cache:set("user:2:name", "Bob")
  print("user:1:name = " .. tostring(cache:get("user:1:name")))
  print("user:2:name = " .. tostring(cache:get("user:2:name")))
  print()

  -- ── Numeric storage and atomic increment ───────────────────────────────────
  print("-- Atomic counters --")
  -- incr with init creates the key if absent.
  for i = 1, 5 do
    cache:incr("page_views", 1, 0)
  end
  print("page_views = " .. tostring(cache:get("page_views")))

  -- Increment by a larger delta.
  cache:incr("bytes_served", 1024, 0)
  cache:incr("bytes_served", 4096)
  print("bytes_served = " .. tostring(cache:get("bytes_served")))
  print()

  -- ── TTL-based expiry ───────────────────────────────────────────────────────
  print("-- TTL / expiry --")
  -- Store a session token valid for 30 seconds.
  cache:set("session:abc123", "user=1;role=admin", 30)
  local ttl_val = cache:ttl("session:abc123")
  print(string.format("session TTL: %.2f s (should be ~30 s)", ttl_val))

  -- Keys without TTL.
  cache:set("config:theme", "dark")
  local cfg_ttl = cache:ttl("config:theme")
  print("config:theme TTL: " .. tostring(cfg_ttl) .. " (should be -1 = no expiry)")
  print()

  -- ── add() / replace() semantics ───────────────────────────────────────────
  print("-- add() / replace() semantics --")
  local ok, add_err = cache:add("lock:resource_A", "worker-1")
  print("add lock (first attempt)  : " .. tostring(ok) .. " err=" .. tostring(add_err))

  local ok2, add_err2 = cache:add("lock:resource_A", "worker-2")
  print("add lock (second attempt) : " .. tostring(ok2) .. " err=" .. tostring(add_err2))
  print("lock holder               : " .. tostring(cache:get("lock:resource_A")))

  cache:replace("lock:resource_A", "worker-3")
  print("after replace             : " .. tostring(cache:get("lock:resource_A")))
  print()

  -- ── flush_expired() ───────────────────────────────────────────────────────
  print("-- flush_expired() --")
  -- Add entries with a past-like TTL (very short, will already be expired
  -- by the time flush_expired runs in a real scenario, but for the demo
  -- we just show the call).
  cache:set("stale:1", "x", 0.001)
  cache:set("stale:2", "y", 0.001)
  -- Give a tiny moment for those to expire (lunet coroutine scheduling).
  lunet.sleep(0.01)
  local flushed = cache:flush_expired()
  print("flush_expired() evicted: " .. tostring(flushed) .. " entries")
  print()

  -- ── Memory stats ──────────────────────────────────────────────────────────
  print("-- Memory stats --")
  print(string.format("Free space now: %d bytes", cache:free_space()))

  print()
  print("=== Demo complete ===")
end)
