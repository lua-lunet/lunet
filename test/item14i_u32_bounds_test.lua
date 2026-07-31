-- RED PHASE (item14): codec u32 bounds + new statuses (unit, no nodes).
-- Fails until item15. Run: luajit test/item14i_u32_bounds_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local root = script_dir .. "/.."
local codec = dofile(root .. "/examples/advisory_lock_cas/codec.lua")

local failures, checks = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        io.stderr:write("FAIL: " .. msg .. "\n")
    else
        print("   OK: " .. msg)
    end
end

-- Out-of-range and malformed u32 fields are rejected at parse time.
check(codec.parse("SET /locks/4294967296 0000000100000000 1 aa000001") == nil,
    "lock_id = 2^32 rejected")
check(codec.parse("SET /locks/1 0000000100000000 4294967296 aa000001") == nil,
    "holder = 2^32 rejected")
check(codec.parse("SET /locks/-1 0000000100000000 1 aa000001") == nil,
    "negative lock_id rejected")
check(codec.parse("SET /locks/1 0000000100000000 -1 aa000001") == nil,
    "negative holder rejected")
check(codec.parse("GET /locks/1.5 aa000001") == nil,
    "fractional lock_id rejected")
check(codec.parse("GET /locks/0x2A aa000001") == nil,
    "hex lock_id rejected (decimal only)")

-- Max u32 values accepted.
local m1 = codec.parse("GET /locks/4294967295 aa000001")
check(m1 ~= nil and m1.lock_id == 4294967295, "lock_id = 2^32-1 accepted")
local m2 = codec.parse("SET /locks/1 0000000100000000 4294967295 aa000001")
check(m2 ~= nil and m2.holder == 4294967295, "holder = 2^32-1 accepted")

-- INVALID and UNAVAILABLE roundtrip.
local inv = codec.format_reply("aa000001", "INVALID")
check(type(inv) == "string", "format_reply INVALID produces a string")
local m3 = codec.parse(inv)
check(m3 ~= nil and m3.type == "REPLY" and m3.status == "INVALID",
    "INVALID reply roundtrips")
local unv = codec.format_reply("aa000001", "UNAVAILABLE")
local m4 = codec.parse(unv)
check(m4 ~= nil and m4.type == "REPLY" and m4.status == "UNAVAILABLE",
    "UNAVAILABLE reply roundtrips")

-- NOT_FOUND is gone.
check(codec.parse("REPLY aa000001 NOT_FOUND") == nil,
    "NOT_FOUND no longer parses")

print(failures > 0
    and ("=== " .. failures .. "/" .. checks .. " FAILURES ===")
    or ("=== all " .. checks .. " checks passed ==="))
os.exit(failures > 0 and 1 or 0)
