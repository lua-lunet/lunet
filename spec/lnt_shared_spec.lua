-- Behavioural suite for the lunet.lnt_shared extension: the public
-- shared-dictionary surface a script author sees through
-- require("lunet.lnt_shared"), per the LuaCATS annotations in
-- types/lunet/lnt_shared.lua. The module is a LuaJIT FFI loader
-- (ext/lnt_shared/lnt_shared.lua) over the POSIX-only Rust library
-- liblnt_shared (anonymous mmap + CLOCK_MONOTONIC).
--
-- Module resolution mirrors spec/paxe_spec.lua and spec/sodium_spec.lua:
-- the loader is the Lua file ext/lnt_shared/lnt_shared.lua, not a C
-- module; package.preload routes require("lunet.lnt_shared") to the
-- dev-tree loader explicitly. The native library is lazy-loaded -- the
-- require succeeds without it and the first open() needs it -- so this
-- suite probes open() once and pends the whole block when
-- liblnt_shared has not been built. The Rust crate's own unit tests
-- (ext/lnt_shared/src/dict.rs) pin the semantics below the FFI
-- boundary; what only this suite can pin is what a script author
-- observes through the Dict handle: the nil-plus-error-string
-- convention, the polymorphic value typing, and the annotated defaults.
--
-- Methods on a closed handle are deliberately not exercised: close()
-- releases the cdata handle, and touching it afterwards is undefined
-- behaviour, not an API contract.

describe("lnt_shared module #native", function()
  local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"
  package.preload["lunet.lnt_shared"] = function()
    return assert(loadfile(spec_dir .. "/../ext/lnt_shared/lnt_shared.lua"))()
  end

  local ok, lnt = pcall(require, "lunet.lnt_shared")
  if not ok then
    pending("lunet.lnt_shared loader not found (ext/lnt_shared/lnt_shared.lua)", function() end)
    return
  end

  -- open() is the first call that touches the native library.
  local native_ok, probe = pcall(lnt.open, "lunet_spec_lnt_shared_probe", 65536)
  if not native_ok then
    pending("liblnt_shared not built (xmake build-lnt-shared)", function() end)
    return
  end

  local function spin(seconds)
    -- Busy-wait: os.clock() measures process CPU time, which a busy
    -- loop advances, so this is a wall-time delay that works everywhere
    -- the suite runs without depending on an extra socket library.
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
      assert(true)
    end
  end

  it("exports open and its store alias", function()
    assert.are.equal("table", type(lnt))
    assert.are.equal("function", type(lnt.open))
    assert.are.equal("function", type(lnt.store))
    assert.are.equal(lnt.open, lnt.store)
  end)

  it("renders the dict identity in tostring", function()
    assert.are.equal("lnt_shared.Dict(lunet_spec_lnt_shared_probe)", tostring(probe))
  end)

  describe("open", function()
    it("requires a non-empty string name", function()
      assert.has_error(function() lnt.open(nil) end)
      assert.has_error(function() lnt.open("") end)
      assert.has_error(function() lnt.open(42) end)
    end)

    it("clamps the size to the 64 KiB minimum", function()
      local d = lnt.open("lunet_spec_lnt_shared_min", 1)
      assert.is_truthy(d:capacity() >= 65536)
    end)

    it("defaults to 1 MiB", function()
      local d = lnt.open("lunet_spec_lnt_shared_default")
      assert.is_truthy(d:capacity() >= 1048576)
    end)

    it("returns handles to the same region for the same name", function()
      local d1 = lnt.open("lunet_spec_lnt_shared_named", 65536)
      local d2 = lnt.open("lunet_spec_lnt_shared_named", 65536)
      d1:flush_all()
      assert.is_true(d1:set("shared", "via d1"))
      assert.are.equal("via d1", d2:get("shared"))
      assert.is_true(d2:set("shared2", "via d2"))
      assert.are.equal("via d2", d1:get("shared2"))
    end)
  end)

  describe("set / get", function()
    local d = lnt.open("lunet_spec_lnt_shared_crud", 65536)

    it("round-trips strings", function()
      assert.is_true(d:set("greeting", "hello"))
      assert.are.equal("hello", d:get("greeting"))
    end)

    it("round-trips numbers as f64", function()
      assert.is_true(d:set("num", 42))
      assert.are.equal(42, d:get("num"))
      assert.is_true(d:set("pi", 3.5))
      assert.are.equal(3.5, d:get("pi"))
      assert.is_true(d:set("neg", -1.25))
      assert.are.equal(-1.25, d:get("neg"))
    end)

    it("round-trips booleans, including false", function()
      assert.is_true(d:set("flag_t", true))
      assert.are.equal("boolean", type(d:get("flag_t")))
      assert.is_true(d:get("flag_t"))
      assert.is_true(d:set("flag_f", false))
      -- false must come back as a boolean, not as the nil of a miss
      assert.are.equal("boolean", type(d:get("flag_f")))
      assert.is_false(d:get("flag_f"))
    end)

    it("round-trips binary strings with NUL bytes", function()
      local blob = "a\0b\0"
      assert.is_true(d:set("blob", blob))
      assert.are.equal(blob, d:get("blob"))
    end)

    it("overwrites an existing key with the last write", function()
      assert.is_true(d:set("ow", "first"))
      assert.is_true(d:set("ow", "second"))
      assert.are.equal("second", d:get("ow"))
    end)

    it("raises on unsupported value types", function()
      assert.has_error(function() d:set("bad", { nested = true }) end)
      local raised, err = pcall(d.set, d, "bad", print)
      assert.is_false(raised)
      assert.matches("unsupported value type", tostring(err))
    end)
  end)

  describe("delete", function()
    local d = lnt.open("lunet_spec_lnt_shared_delete", 65536)

    it("reports not found for a missing key", function()
      local v, err = d:get("nope")
      assert.is_nil(v)
      assert.are.equal("not found", err)
    end)

    it("deletes an existing key and reports not found after", function()
      assert.is_true(d:set("doomed", "value"))
      assert.is_true(d:delete("doomed"))
      local v, err = d:get("doomed")
      assert.is_nil(v)
      assert.are.equal("not found", err)
      local ok_del, err2 = d:delete("doomed")
      assert.is_nil(ok_del)
      assert.are.equal("not found", err2)
    end)

    it("allows setting a key again after delete", function()
      assert.is_true(d:set("recycled", "v1"))
      assert.is_true(d:delete("recycled"))
      assert.is_true(d:set("recycled", "v2"))
      assert.are.equal("v2", d:get("recycled"))
    end)
  end)

  describe("add / replace", function()
    local d = lnt.open("lunet_spec_lnt_shared_addrep", 65536)

    it("adds only when the key is absent", function()
      assert.is_true(d:add("lock", "first"))
      local ok_add, err = d:add("lock", "second")
      assert.is_nil(ok_add)
      assert.are.equal("already exists", err)
      assert.are.equal("first", d:get("lock"))
    end)

    it("replaces only when the key exists", function()
      local ok_rep, err = d:replace("absent", "x")
      assert.is_nil(ok_rep)
      assert.are.equal("not found", err)
      assert.is_true(d:set("existing", "v1"))
      assert.is_true(d:replace("existing", "v2"))
      assert.are.equal("v2", d:get("existing"))
    end)
  end)

  describe("counter semantics (incr)", function()
    local d = lnt.open("lunet_spec_lnt_shared_incr", 65536)

    it("increments an existing numeric key by 1 by default", function()
      assert.is_true(d:set("n", 10))
      assert.are.equal(11, d:incr("n"))
    end)

    it("applies an explicit delta, including fractions", function()
      assert.is_true(d:set("n2", 1))
      assert.are.equal(6, d:incr("n2", 5))
      assert.are.equal(6.25, d:incr("n2", 0.25))
    end)

    it("initialises a missing key to init before incrementing", function()
      assert.are.equal(105, d:incr("fresh", 5, 100))
      assert.are.equal(105, d:get("fresh"))
    end)

    it("reports not found for a missing key without init", function()
      local v, err = d:incr("missing")
      assert.is_nil(v)
      assert.are.equal("not found", err)
    end)

    it("reports a type mismatch for non-numeric keys", function()
      assert.is_true(d:set("s", "string"))
      local v, err = d:incr("s")
      assert.is_nil(v)
      assert.are.equal("type mismatch", err)
      assert.is_true(d:set("b", true))
      local v2, err2 = d:incr("b")
      assert.is_nil(v2)
      assert.are.equal("type mismatch", err2)
    end)
  end)

  describe("TTL handling", function()
    local d = lnt.open("lunet_spec_lnt_shared_ttl", 65536)

    it("reports -1 for keys without expiry", function()
      assert.is_true(d:set("permanent", "v"))
      assert.are.equal(-1, d:ttl("permanent"))
    end)

    it("reports the remaining seconds for keys with expiry", function()
      assert.is_true(d:set("temporary", "v", 60))
      local remaining = d:ttl("temporary")
      assert.is_truthy(remaining > 0 and remaining <= 60)
    end)

    it("reports not found for a missing key", function()
      local v, err = d:ttl("nope")
      assert.is_nil(v)
      assert.are.equal("not found", err)
    end)

    it("adds and removes an expiry with expire", function()
      assert.is_true(d:set("adjustable", "v"))
      assert.is_true(d:expire("adjustable", 60))
      assert.is_truthy(d:ttl("adjustable") > 0)
      -- an expire of 0 removes the expiry again
      assert.is_true(d:expire("adjustable", 0))
      assert.are.equal(-1, d:ttl("adjustable"))
      local ok_exp, err = d:expire("still missing", 60)
      assert.is_nil(ok_exp)
      assert.are.equal("not found", err)
    end)

    it("lets expired keys vanish and counts them in flush_expired", function()
      d:flush_all()
      assert.is_true(d:set("e1", "v", 0.05))
      assert.is_true(d:set("e2", "v", 0.05))
      assert.is_true(d:set("keep", "v"))
      spin(0.2)
      -- flush_expired counts every expired entry before any get
      -- tombstones them individually
      assert.are.equal(2, d:flush_expired())
      -- a key without expiry survives the sweep
      assert.are.equal("v", d:get("keep"))
      -- get treats an expired entry as absent
      local v, err = d:get("e1")
      assert.is_nil(v)
      assert.are.equal("not found", err)
    end)

    it("honours the max limit in flush_expired", function()
      d:flush_all()
      assert.is_true(d:set("f1", "v", 0.05))
      assert.is_true(d:set("f2", "v", 0.05))
      assert.is_true(d:set("f3", "v", 0.05))
      spin(0.2)
      assert.are.equal(1, d:flush_expired(1))
      assert.are.equal(2, d:flush_expired())
    end)
  end)

  describe("capacity and flush_all", function()
    local d = lnt.open("lunet_spec_lnt_shared_cap", 65536)

    it("reports capacity and free space in bytes", function()
      local cap = d:capacity()
      assert.is_truthy(cap >= 65536)
      local free = d:free_space()
      assert.is_truthy(free > 0 and free <= cap)
    end)

    it("clears every key and resets the allocator", function()
      d:flush_all()
      local free_before = d:free_space()
      for _ = 1, 10 do
        assert.is_true(d:set("k", string.rep("x", 1024)))
      end
      -- the bump allocator never reclaims on overwrite
      assert.is_truthy(d:free_space() < free_before)
      d:flush_all()
      assert.are.equal(free_before, d:free_space())
      local v, err = d:get("k")
      assert.is_nil(v)
      assert.are.equal("not found", err)
    end)
  end)

  describe("close", function()
    it("is idempotent and returns true", function()
      local d = lnt.open("lunet_spec_lnt_shared_close", 65536)
      assert.is_true(d:close())
      assert.is_true(d:close())
    end)
  end)
end)
