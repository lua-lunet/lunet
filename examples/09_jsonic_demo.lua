--[[
jsonic Extension Demo for lunet
===============================

Demonstrates lunet.jsonic — a dkjson-style JSON encode/decode API where
decode is backed by a fast, dependency-free Rust JSON parser (jsonic,
https://github.com/g1mv/jsonic). encode() is plain Lua (jsonic itself only
parses; it does not serialise).

Prerequisites
  1. Build the Rust extension once:
       cd ext/jsonic && cargo build --release
     Or via xmake:
       xmake build-jsonic

  2. Run this example:
       LUNET_JSONIC_LIB=ext/jsonic/target/release/liblunet_jsonic.dylib \
       ./build/macosx/arm64/release/lunet-run examples/09_jsonic_demo.lua
     Or via xmake:
       xmake jsonic-smoke  (runs test/smoke_jsonic.lua, not this file)
]]

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ext_lua = script_dir .. "/../ext/jsonic/jsonic.lua"
local chunk, err = loadfile(ext_lua)
if not chunk then
  error("Cannot find jsonic.lua: " .. tostring(err) ..
        "\nBuild with: cd ext/jsonic && cargo build --release")
end
local json = chunk()

local lunet = require("lunet")

lunet.spawn(function()
  print("=== lunet.jsonic Demo ===")
  print()

  -- ── Decoding ───────────────────────────────────────────────────────────────
  print("-- Decode --")
  local payload = [[
    {
      "name": "lunet",
      "version": 1,
      "tags": ["fast", "small", "zero-dep"],
      "active": true,
      "deprecated_field": null,
      "pi": 3.14159,
      "greeting": "Hello,\nworld! caf\u00e9"
    }
  ]]
  local value, _, decode_err = json.decode(payload)
  if not value then
    error("decode failed: " .. tostring(decode_err))
  end
  print("name          = " .. value.name)
  print("version       = " .. value.version)
  print("tags[1..3]    = " .. table.concat(value.tags, ", "))
  print("active        = " .. tostring(value.active))
  print("deprecated    = " .. tostring(value.deprecated_field == json.null) .. " (is json.null)")
  print("pi            = " .. tostring(value.pi))
  print("greeting      = " .. value.greeting)
  print()

  -- ── Error handling ─────────────────────────────────────────────────────────
  print("-- Error handling --")
  local bad, _, bad_err = json.decode("{not valid json}")
  print("decode('{not valid json}') -> value=" .. tostring(bad) .. " err=" .. tostring(bad_err))
  print()

  -- ── Encoding ───────────────────────────────────────────────────────────────
  print("-- Encode --")
  local compact = json.encode({ a = 1, b = { 1, 2, 3 }, c = "hi", d = json.null }, { keyorder = { "a", "b", "c", "d" } })
  print("compact: " .. compact)

  local pretty = json.encode({ a = 1, nested = { b = 2 } }, { indent = true, keyorder = { "a", "nested" } })
  print("indented:")
  print(pretty)
  print()

  -- ── Round-trip ─────────────────────────────────────────────────────────────
  print("-- Round-trip --")
  local original = { numbers = { 1, 2, 3 }, flag = true, note = "quotes \"work\" too" }
  local encoded = json.encode(original, { keyorder = { "name", "values" } })
  local decoded = json.decode(encoded)
  print("original.note == decoded.note: " .. tostring(original.note == decoded.note))
  print("original.numbers[3] == decoded.numbers[3]: " .. tostring(original.numbers[3] == decoded.numbers[3]))

  print()
  print("=== Demo complete ===")
end)
