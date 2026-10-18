-- Behavioural suite for the lunet.jsonic extension: the public JSON
-- surface a script author sees through require("lunet.jsonic"). The
-- module is a LuaJIT FFI loader (ext/jsonic/jsonic.lua) that binds the
-- dkjson 2.10 encoder and a Rust tagged-buffer decoder
-- (liblunet_jsonic) behind one table.
--
-- Module resolution mirrors spec/paxe_spec.lua and spec/sodium_spec.lua:
-- the loader is the Lua file ext/jsonic/jsonic.lua, not a C module;
-- package.preload routes require("lunet.jsonic") to the dev-tree loader
-- explicitly. Unlike sodium, the native library is lazy-loaded -- the
-- require succeeds without it and the first decode needs it -- so this
-- suite probes the decoder once: the encode half is pure Lua and runs
-- regardless, and the decode/round-trip halves pend when
-- liblunet_jsonic has not been built.

describe("jsonic module #native", function()
  local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"
  package.preload["lunet.jsonic"] = function()
    return assert(loadfile(spec_dir .. "/../ext/jsonic/jsonic.lua"))()
  end

  local ok, jsonic = pcall(require, "lunet.jsonic")
  if not ok then
    pending("lunet.jsonic loader not found (ext/jsonic/jsonic.lua)", function() end)
    return
  end

  -- A missing native library surfaces as an error from the first decode,
  -- not from the require above. The probe payload is a root container:
  -- the upstream jsonic parser only accepts arrays and objects as the
  -- root value (root scalars, including "null", report a parse error).
  local native_ok = pcall(jsonic.decode, "[1]")

  it("exports the dkjson v2 encoder surface", function()
    assert.are.equal("table", type(jsonic))
    assert.are.equal("function", type(jsonic.encode))
    assert.are.equal("function", type(jsonic.decode))
    assert.are.equal("dkjson 2.10", jsonic.version)
  end)

  it("exposes the null sentinel", function()
    -- The sentinel is its own value (not nil) that encodes as JSON null.
    assert.is_true(jsonic.null ~= nil)
    assert.are.equal("null", jsonic.encode(jsonic.null))
  end)

  describe("encode (dkjson backend)", function()
    it("encodes an object with an explicit key order", function()
      assert.are.equal('{"a":1,"b":"x"}',
        jsonic.encode({ a = 1, b = "x" }, { keyorder = { "a", "b" } }))
    end)

    it("encodes an array", function()
      assert.are.equal("[1,2,3]", jsonic.encode({ 1, 2, 3 }))
    end)

    it("encodes mixed scalar types", function()
      assert.are.equal('{"s":"hi","n":1,"t":true,"f":false,"z":null}',
        jsonic.encode({ s = "hi", n = 1, t = true, f = false, z = jsonic.null },
                      { keyorder = { "s", "n", "t", "f", "z" } }))
    end)

    it("escapes control characters, quotes and backslashes", function()
      assert.are.equal('"a\\nb\\tc\\"d\\\\e"', jsonic.encode('a\nb\tc"d\\e'))
    end)

    it("encodes an empty table as an empty container", function()
      local s = jsonic.encode({})
      assert.is_true(s == "[]" or s == "{}")
    end)

    it("encodes a sparse array with a null hole", function()
      local t = { "a" }
      t[3] = "c"
      assert.are.equal('["a",null,"c"]', jsonic.encode(t))
    end)

    it("encodes NaN as null", function()
      assert.are.equal("null", jsonic.encode(0 / 0))
    end)

    it("supports indented output", function()
      local s = jsonic.encode({ a = 1 }, { indent = true })
      assert.is_truthy(s:find("\n", 1, true))
    end)

    it("raises on a reference cycle", function()
      local t = {}
      t.self = t
      local raised, err = pcall(jsonic.encode, t)
      assert.is_false(raised)
      assert.matches("cycle", tostring(err))
    end)

    it("raises on unsupported value types", function()
      local raised, err = pcall(jsonic.encode, print)
      assert.is_false(raised)
      assert.matches("not supported by JSON", tostring(err))
    end)

    it("raises on non-string keys", function()
      local raised, err = pcall(jsonic.encode, { [true] = 1 })
      assert.is_false(raised)
      assert.matches("not supported as a key", tostring(err))
    end)
  end)

  -- Fixed-shape render helpers; single escaping/formatting authority.
  describe("fixed-shape renderers", function()
    it("quotes a string identically to encode", function()
      local s = 'a\nb\tc"d\\e\127'
      assert.are.equal(jsonic.encode(s), jsonic.jstr(s))
      assert.are.equal('"hi"', jsonic.jstr("hi"))
    end)

    it("falls back to encode for non-string scalars", function()
      assert.are.equal(jsonic.encode(42), jsonic.jstr(42))
      assert.are.equal(jsonic.encode(true), jsonic.jstr(true))
      assert.are.equal(jsonic.encode(jsonic.null), jsonic.jstr(jsonic.null))
    end)

    it("renders integers exactly (zero, negative, large)", function()
      assert.are.equal("0", jsonic.jint(0))
      assert.are.equal("-7", jsonic.jint(-7))
      assert.are.equal("2147483648", jsonic.jint(2147483648))
      assert.are.equal("9.007199254741e+15", jsonic.jint(9007199254740992))
      assert.are.equal(jsonic.encode(9007199254740992), jsonic.jint(9007199254740992))
    end)

    it("shares one number-rendering authority with encode", function()
      -- non-finite numbers render as null (encode's number branch), not
      -- the invalid JSON literals tostring would emit
      assert.are.equal("null", jsonic.jint(0 / 0))
      assert.are.equal(jsonic.encode(-1 / 0), jsonic.jint(-1 / 0))
    end)

    it("renders non-number scalars through the encoder", function()
      -- the submission contract type-checks nothing: off-domain scalars
      -- take the same rendering path as encode, unsupported types raise
      assert.are.equal(jsonic.encode("5"), jsonic.jint("5"))
      assert.are.equal("null", jsonic.jint(nil))
      local raised, err = pcall(jsonic.jint, print)
      assert.is_false(raised)
      assert.matches("not supported by JSON", tostring(err))
    end)
  end)

  if not native_ok then
    pending("liblunet_jsonic not built (xmake build-jsonic)", function() end)
    return
  end

  describe("decode", function()
    it("decodes every scalar type", function()
      local v = jsonic.decode('{"s":"hello","t":true,"f":false,"n":null,"pi":3.5}')
      assert.are.equal("hello", v.s)
      assert.is_true(v.t)
      assert.is_false(v.f)
      assert.is_true(v.n == jsonic.null)
      assert.are.equal(3.5, v.pi)
    end)

    it("decodes nested and empty containers", function()
      local v = jsonic.decode('{"a":{"b":{"c":[1,2,3]}},"e":[],"o":{}}')
      assert.are.equal(1, v.a.b.c[1])
      assert.are.equal(3, v.a.b.c[3])
      assert.are.equal(0, #v.e)
      assert.are.equal(0, #v.o)
    end)

    it("decodes string escapes, \\u sequences and surrogate pairs", function()
      local v = jsonic.decode('{"nl":"a\\nb","tab":"c\\td","q":"say \\"hi\\"",' ..
        '"bs":"a\\\\b","acc":"caf\\u00e9","emoji":"\\ud83d\\ude00"}')
      assert.are.equal("a\nb", v.nl)
      assert.are.equal("c\td", v.tab)
      assert.are.equal('say "hi"', v.q)
      assert.are.equal("a\\b", v.bs)
      assert.are.equal("café", v.acc)
      assert.are.equal("\240\159\152\128", v.emoji)
    end)

    it("reports the position after the decoded value", function()
      local v, pos = jsonic.decode('{"a":1}')
      assert.are.equal(1, v.a)
      assert.are.equal(8, pos)
    end)

    it("starts decoding at a given position", function()
      local v, pos = jsonic.decode('   {"a":1}', 4)
      assert.are.equal(1, v.a)
      -- next position is the start position plus the consumed input length
      assert.are.equal(11, pos)
    end)

    it("maps JSON null to a caller-supplied sentinel", function()
      local v = jsonic.decode('["a",null]', nil, "MISSING")
      assert.are.equal("a", v[1])
      assert.are.equal("MISSING", v[2])
    end)

    it("returns nil plus error for malformed JSON without raising", function()
      local v, pos, err = jsonic.decode("{not valid json}")
      assert.is_nil(v)
      -- the loader reports the position parsing started at
      assert.are.equal(1, pos)
      assert.are.equal("string", type(err))
      assert.is_truthy(#err > 0)
      -- parse failures return, they do not error out
      local raised = pcall(jsonic.decode, "completely invalid")
      assert.is_true(raised)
    end)

    it("raises on a non-string argument", function()
      local raised, err = pcall(jsonic.decode, 12345)
      assert.is_false(raised)
      assert.matches("expected a string", tostring(err))
    end)
  end)

  describe("round-trip", function()
    it("preserves a nested payload through encode/decode", function()
      local original = {
        name = "lunet",
        count = 42,
        pi = 3.14159,
        tags = { "fast", "small" },
        nested = { deep = { flag = true, off = false, nothing = jsonic.null } },
      }
      local decoded = jsonic.decode(jsonic.encode(original))
      assert.are.equal("lunet", decoded.name)
      assert.are.equal(42, decoded.count)
      assert.are.equal(3.14159, decoded.pi)
      assert.are.equal(2, #decoded.tags)
      assert.are.equal("fast", decoded.tags[1])
      assert.are.equal("small", decoded.tags[2])
      assert.is_true(decoded.nested.deep.flag)
      assert.is_false(decoded.nested.deep.off)
      assert.is_true(decoded.nested.deep.nothing == jsonic.null)
    end)

    it("round-trips a string that contains JSON syntax", function()
      local s = '{"looks":"like json"}'
      assert.are.equal(s, jsonic.decode(jsonic.encode({ payload = s })).payload)
    end)

    it("round-trips strings with control characters", function()
      -- Control bytes are escaped on encode, so the payload stays
      -- ASCII-safe across the native decoder.
      local blob = "\0\1\31"
      assert.are.equal(blob, jsonic.decode(jsonic.encode({ blob = blob })).blob)
    end)
  end)
end)
