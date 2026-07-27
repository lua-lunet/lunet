-- Smoke test for lunet.jsonic extension
--
-- Before running this test, build the Rust extension:
--   xmake build-jsonic
-- Then run via the jsonic-smoke task:
--   xmake jsonic-smoke
-- Or manually:
--   LUNET_JSONIC_LIB=ext/jsonic/target/release/liblunet_jsonic.dylib \
--   lunet-run test/smoke_jsonic.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ext_dir = script_dir .. "/../ext/jsonic"

local function load_jsonic()
  local full_path = ext_dir .. "/jsonic.lua"
  local chunk, err = loadfile(full_path)
  if not chunk then
    error("Cannot load jsonic.lua: " .. tostring(err))
  end
  return chunk()
end

local lunet = require("lunet")

local function test_jsonic()
  print("=== jsonic Smoke Test ===")
  print()

  print("1. Loading lunet.jsonic ...")
  local ok, json = pcall(load_jsonic)
  if not ok then
    print("FAIL: " .. tostring(json))
    __lunet_exit_code = 1
    return
  end
  print("   OK: module loaded")

  local step = 1
  local function fail(msg)
    print("FAIL: " .. msg)
    __lunet_exit_code = 1
    error("__smoke_abort__", 0)
  end
  local function ok_step(msg)
    step = step + 1
    print(("   OK (%d): %s"):format(step, msg))
  end
  local function check(cond, msg)
    if not cond then fail(msg) end
  end

  local aborted = select(2, pcall(function()

  -- ── Basic scalar decode ────────────────────────────────────────────────────
  do
    local v, _, err = json.decode('{"a":1}')
    check(v ~= nil and err == nil, "decode simple object failed: " .. tostring(err))
    check(v.a == 1, "expected a=1")
  end
  ok_step("decode simple object")

  do
    local v = json.decode('{"s":"hello","b":true,"f":false,"n":null,"pi":3.14159}')
    check(v.s == "hello", "string field")
    check(v.b == true, "true field")
    check(v.f == false, "false field")
    check(v.n == json.null, "null field should equal json.null sentinel")
    check(math.abs(v.pi - 3.14159) < 1e-9, "float field")
  end
  ok_step("decode all scalar types")

  -- ── Nesting ────────────────────────────────────────────────────────────────
  do
    local v = json.decode('{"a":{"b":{"c":[1,2,3]}}}')
    check(v.a.b.c[1] == 1 and v.a.b.c[2] == 2 and v.a.b.c[3] == 3, "nested array")
  end
  ok_step("decode nested objects/arrays")

  do
    local v = json.decode('[1,"two",true,null,[3],{"k":4}]')
    check(v[1] == 1, "array[1]")
    check(v[2] == "two", "array[2]")
    check(v[3] == true, "array[3]")
    check(v[4] == json.null, "array[4] null")
    check(v[5][1] == 3, "array[5] nested array")
    check(v[6].k == 4, "array[6] nested object")
  end
  ok_step("decode array of mixed types")

  -- ── Escapes / unicode ──────────────────────────────────────────────────────
  do
    local v = json.decode('{"s":"line1\\nline2\\ttab"}')
    check(v.s == "line1\nline2\ttab", "escape sequences decoded")
  end
  ok_step("decode string escapes (\\n, \\t)")

  do
    local v = json.decode('{"s":"quo\\"te\\\\slash"}')
    check(v.s == 'quo"te\\slash', "quote/backslash escapes decoded")
  end
  ok_step("decode quote and backslash escapes")

  do
    local v = json.decode('{"caf\\u00e9":"r\\u00e9sum\\u00e9"}')
    check(v["café"] == "résumé", "unicode BMP escapes in key and value")
  end
  ok_step("decode \\u BMP escapes in keys and values")

  do
    local v = json.decode('{"emoji":"\\ud83d\\ude00"}')
    check(v.emoji == "\240\159\152\128", "surrogate pair decodes to correct UTF-8 bytes")
  end
  ok_step("decode \\u surrogate pair")

  -- ── Empty containers ───────────────────────────────────────────────────────
  do
    local v = json.decode('{"e":[],"o":{}}')
    check(type(v.e) == "table" and next(v.e) == nil, "empty array")
    check(type(v.o) == "table" and next(v.o) == nil, "empty object")
  end
  ok_step("decode empty array and object")

  -- ── Error handling ─────────────────────────────────────────────────────────
  do
    local v, _, err = json.decode("{not valid json}")
    check(v == nil, "invalid JSON should return nil value")
    check(type(err) == "string" and #err > 0, "invalid JSON should return an error message")
  end
  ok_step("decode invalid JSON returns nil + error message")

  do
    local ok_call = pcall(json.decode, "not even close to json")
    -- decode itself never raises for parse errors (returns nil+err instead);
    -- confirm it truly doesn't error out here.
    check(ok_call == true, "decode of garbage must not raise a Lua error")
  end
  ok_step("decode of garbage does not raise")

  do
    local ok_call, _ = pcall(json.decode, 12345)
    check(ok_call == false, "decode of a non-string must raise")
  end
  ok_step("decode of non-string argument raises")

  -- ── Encode ─────────────────────────────────────────────────────────────────
  do
    local s = json.encode({ a = 1 }, { keyorder = { "a" } })
    check(s == '{"a":1}', "encode simple object, got " .. s)
  end
  ok_step("encode simple object")

  do
    local s = json.encode({ 1, 2, 3 })
    check(s == "[1,2,3]", "encode simple array, got " .. s)
  end
  ok_step("encode simple array")

  do
    local s = json.encode({ a = 1, b = "two", c = true, d = json.null }, { keyorder = { "a", "b", "c", "d" } })
    check(s == '{"a":1,"b":"two","c":true,"d":null}', "encode mixed types, got " .. s)
  end
  ok_step("encode mixed scalar types with sorted keys")

  do
    local s = json.encode("hi\nthere\t\"quoted\"")
    check(s == '"hi\\nthere\\t\\"quoted\\""', "encode escapes string, got " .. s)
  end
  ok_step("encode escapes control chars and quotes")

  do
    local s = json.encode({})
    check(s == "{}" or s == "[]", "encode empty table, got " .. s)
  end
  ok_step("encode empty table")

  do
    -- dkjson treats this as a sparse array and emits a null for the hole.
    local t = {}
    t[1] = "a"
    t[3] = "c"
    local s = json.encode(t)
    check(s == '["a",null,"c"]', "sparse table must encode as array with null hole, got " .. s)
  end
  ok_step("encode sparse table as array with null hole")

  do
    local ok_call = pcall(json.encode, 0 / 0)
    check(ok_call == true, "encode of NaN must not raise")
    check(json.encode(0 / 0) == "null", "encode of NaN should serialize as null")
  end
  ok_step("encode of NaN serializes as null")

  do
    local t = {}
    t.self = t
    local ok_call = pcall(json.encode, t)
    check(ok_call == false, "encode of a cyclic table must raise")
  end
  ok_step("encode of cyclic table raises")

  -- ── Round-trip ─────────────────────────────────────────────────────────────
  do
    local original = {
      name = "lunet",
      version = 1,
      tags = { "fast", "small", "zero-dep" },
      active = true,
      deleted = false,
      meta = json.null,
      nested = { a = { b = { c = 42 } } },
    }
    local encoded = json.encode(original)
    local decoded = json.decode(encoded)
    check(decoded.name == "lunet", "round-trip name")
    check(decoded.version == 1, "round-trip version")
    check(decoded.tags[1] == "fast" and decoded.tags[3] == "zero-dep", "round-trip tags")
    check(decoded.active == true and decoded.deleted == false, "round-trip booleans")
    check(decoded.meta == json.null, "round-trip null")
    check(decoded.nested.a.b.c == 42, "round-trip deep nesting")
  end
  ok_step("full encode/decode round-trip")

  -- ── Indent option ──────────────────────────────────────────────────────────
  do
    local s = json.encode({ a = 1 }, { indent = true })
    check(s:find("\n") ~= nil, "indented encode should contain newlines")
    local v = json.decode(s)
    check(v.a == 1, "indented output must still decode correctly")
  end
  ok_step("encode with indent produces valid, re-decodable JSON")

  end)) -- end of protected block
  if aborted ~= "__smoke_abort__" and aborted ~= nil then
    print("FAIL (unexpected): " .. tostring(aborted))
    __lunet_exit_code = 1
  end
  if __lunet_exit_code ~= 1 then
    print()
    print("=== All jsonic tests passed (" .. step .. " checks) ===")
    __lunet_exit_code = 0
  end
end

lunet.spawn(test_jsonic)
