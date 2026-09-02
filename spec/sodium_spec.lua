-- Behavioural suite for the lunet.sodium extension: the Lua boundary of
-- the three lunet_sodium_* shims in the PAXE cdylib — argument
-- validation, error conventions, and known-answer vectors. The crate
-- internals are pinned by ext/paxe's own Rust suite (which drives the
-- same exports at the C level); what ONLY this suite can pin is what a
-- script author observes through require("lunet.sodium").
--
-- NO-PANIC GUARANTEE, tested from Lua: the cdylib is built
-- panic = "abort", so a Rust panic reachable from any input below
-- kills this busted process outright and fails the whole run
-- unmistakably. Every "raises" assertion is therefore also a
-- no-crash assertion.
--
-- KNOWN-ANSWER VECTORS: SHA-256 digests are FIPS 180-4 vectors; the
-- HMAC-SHA-256 tags were computed with an independent implementation
-- (Python's hmac module) against libsodium's FIXED 32-byte HMAC key
-- size, so a wrong FFI binding fails loudly here.
--
-- Module resolution mirrors spec/paxe_spec.lua: the FFI loader is the
-- Lua file ext/paxe/sodium.lua, not a C module; package.preload routes
-- require("lunet.sodium") to the dev-tree loader explicitly, and the
-- pending gate fires exactly when the cdylib is absent (the loader
-- raises at load time when it cannot find liblunet_paxe).

describe("Sodium Module #native", function()
  local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"
  package.preload["lunet.sodium"] = function()
    return assert(loadfile(spec_dir .. "/../ext/paxe/sodium.lua"))()
  end

  local ok, sodium = pcall(require, "lunet.sodium")
  if not ok then
    pending("lunet.sodium not built (xmake build-paxe)", function() end)
    return
  end

  local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end

  it("exports the digest size constant", function()
    assert.equals(32, sodium.BYTES)
  end)

  it("sha256 produces the FIPS 180-4 known answers", function()
    assert.equals(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      hex(sodium.sha256("abc")))
    assert.equals(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      hex(sodium.sha256("")))
    assert.equals(
      "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
      hex(sodium.sha256("The quick brown fox jumps over the lazy dog")))
  end)

  it("sha256 returns raw 32-byte strings", function()
    assert.equals(32, #sodium.sha256("x"))
    -- Binary safety: NUL bytes pass through untouched.
    assert.equals(32, #sodium.sha256("a\x00b\x00"))
    assert.equals(sodium.sha256("a\x00b\x00"), sodium.sha256("a\x00b\x00"))
  end)

  it("hmac_sha256 produces independent-implementation known answers", function()
    local k1 = string.rep("\11", 32)
    assert.equals(32, #k1)
    assert.equals(
      "198a607eb44bfbc69903a0f1cf2bbdc5ba0aa3f3d9ae3c1c7a3b1696a0b68cf7",
      hex(sodium.hmac_sha256("Hi There", k1)))
    local k2 = "01234567890123456789012345678901"
    assert.equals(32, #k2)
    assert.equals(
      "385bb9f6f70ceb6ae2c6a918e0fd024ff3cb38aca35f43cb9c67611ec1791662",
      hex(sodium.hmac_sha256("lunet.sodium known-answer", k2)))
    local k3 = ""
    for i = 0, 31 do k3 = k3 .. string.char(i) end
    assert.equals(
      "d38b42096d80f45f826b44a9d5607de72496a415d3f4a1a8c88e3bb9da8dc1cb",
      hex(sodium.hmac_sha256("", k3)))
  end)

  it("hmac_sha256 is deterministic and key-sensitive", function()
    local key = string.rep("\42", 32)
    local t1 = sodium.hmac_sha256("payload", key)
    local t2 = sodium.hmac_sha256("payload", key)
    assert.equals(t1, t2)
    assert.not_equals(t1, sodium.hmac_sha256("payload", string.rep("\43", 32)))
    assert.not_equals(t1, sodium.hmac_sha256("payload2", key))
  end)

  it("hmac_sha256 raises on a wrong key length", function()
    for _, bad in ipairs({ "", string.rep("k", 31), string.rep("k", 33) }) do
      local raised, err = pcall(sodium.hmac_sha256, "data", bad)
      assert.is_false(raised, "key length " .. #bad .. " must raise")
      assert.truthy(tostring(err):find("exactly 32 bytes", 1, true),
        "message names the constraint, got: " .. tostring(err))
    end
  end)

  it("random draws the requested number of unpredictable bytes", function()
    assert.equals(0, #sodium.random(0))
    assert.equals(1, #sodium.random(1))
    local a = sodium.random(64)
    local b = sodium.random(64)
    assert.equals(64, #a)
    assert.not_equals(a, b)
    -- Lenient shape check over a bigger sample (an all-zero or all-0xFF
    -- fill is not random; anything finer-grained would be flaky).
    local big = sodium.random(1024)
    assert.equals(1024, #big)
    assert.truthy(big:find("[^%z]") ~= nil, "all-zero fill is not random")
  end)

  it("malformed arguments raise with the argument named", function()
    local cases = {
      { fn = sodium.sha256, args = { 42 }, want = "string expected" },
      { fn = sodium.sha256, args = { nil }, want = "string expected" },
      { fn = sodium.hmac_sha256, args = { "data", 42 }, want = "string expected" },
      { fn = sodium.hmac_sha256, args = { 42, string.rep("k", 32) }, want = "string expected" },
      { fn = sodium.random, args = { -1 }, want = "non%-negative" },
      { fn = sodium.random, args = { 1.5 }, want = "non%-negative" },
      { fn = sodium.random, args = { "8" }, want = "non%-negative" },
      { fn = sodium.random, args = {}, want = "non%-negative" },
    }
    for _, c in ipairs(cases) do
      local raised, err = pcall(c.fn, unpack(c.args))
      assert.is_false(raised, ("args %s must raise"):format(tostring(c.args[1])))
      assert.truthy(tostring(err):find(c.want),
        "message should match " .. c.want .. ", got: " .. tostring(err))
    end
  end)

  it("works in a process that never configures PAXE", function()
    -- The shims share only the cdylib with lunet.paxe, not its state:
    -- no init()/set_local_id() is required or performed anywhere in
    -- this suite, and calling the primitives must not disturb PAXE
    -- counters (paxe_spec pins the counter invariants on its side).
    assert.truthy(#sodium.sha256("standalone") == 32)
    assert.truthy(#sodium.random(8) == 8)
  end)
end)
