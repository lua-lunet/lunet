-- Behavioural suite for the lunet.paxe extension: the Lua boundary of
-- the Rust cdylib — argument validation, return shapes, error
-- conventions, key lifecycle, opaque rejection and round trips. The
-- crate internals and the wire format are pinned by paxe-core's own
-- suite (known-answer vectors included); what ONLY this suite can pin
-- is what a script author observes.
--
-- NO-PANIC GUARANTEE, tested from Lua: the cdylib is built
-- panic = "abort", so a Rust panic reachable from any input below
-- kills this busted process outright and fails the whole run
-- unmistakably. Every "raises" assertion is therefore also a
-- no-crash assertion.
--
-- RESET DISCIPLINE: the module holds process-global state — the
-- keystore, the local node identity, the failure policy, the log-once
-- memo, and cumulative counters that NEVER reset while the process
-- lives. busted runs the whole spec/ directory in ONE process, so
-- every test re-establishes its own preconditions in before_each:
-- shutdown() (forgets the identity, zeroes every key, resets the
-- log-once memo) + init() (idempotent) + set_local_id() + the policy
-- pinned to "silent". Tests that need a different identity
-- reconfigure() locally.
--
-- COUNTER DELTAS ONLY: stats() snapshots are cumulative; an absolute
-- assertion passes in isolation and breaks when a test is inserted
-- before it. The deltas() helper below snapshots before/after a
-- window and returns per-counter differences; no absolute counter
-- assertion appears anywhere in this file.
--
-- OUT OF SCOPE (recorded homes): the failure-policy stderr lines
-- ([PAXE] drop: ...) require subprocess capture — busted cannot
-- intercept a C-level fprintf — and are test/smoke_paxe.lua's job. Full
-- protected-socket UDP send/recv end-to-end is test/run_paxe_udp_e2e.sh;
-- only the protect/unprotect behaviour reachable without the lunet
-- runtime loop is covered here. DEK-mode frames cannot be SEALED through
-- this API (the C ABI exposes one-recipient standard sealing only), so
-- the open-side DEK dispatch is pinned in the crate's suite, not here.
--
-- bit.bxor, NOT Lua 5.3's `~`: LuaJIT's parser is 5.1-based and some
-- builds (Debian trixie's) reject `~` at parse time, which would skip
-- this entire suite with zero checks run.

local bit = require("bit")

describe("PAXE Module #native", function()
  -- Module resolution: the FFI loader is the Lua file
  -- ext/paxe/paxe.lua, NOT a C module under build/**/<mode>/lunet
  -- (the LUA_CPATH that xmake's test task exports covers only *.so).
  -- In this dev checkout no lunet/paxe.lua sits on package.path, so
  -- require("lunet.paxe") is routed to the dev-tree loader explicitly
  -- via package.preload. This is load-bearing defensively as well:
  -- build/**/<mode>/lunet may still hold a STALE paxe.so from the
  -- deleted C implementation exporting the OLD API; package.preload is
  -- searched before package.cpath, so the Rust-backed loader always
  -- wins. The pending gate still fires exactly when the cdylib is
  -- absent: paxe.lua reads the protocol constants from the library at
  -- load time and raises when the library cannot be found.
  local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"
  package.preload["lunet.paxe"] = function()
    return assert(loadfile(spec_dir .. "/../ext/paxe/paxe.lua"))()
  end

  local ok, paxe = pcall(require, "lunet.paxe")
  if not ok then
    pending("lunet.paxe not built (xmake build-paxe)", function() end)
    return
  end

  -- init() reports nil, message on hosts without the AES-256-GCM
  -- hardware path (an environment property — e.g. the documented
  -- Debian trixie arm64 distro-libsodium case), not a defect: a clean
  -- pending, same gate as test/smoke_paxe.lua's clean skip.
  local init_ok, init_err = paxe.init()
  if not init_ok then
    pending("lunet.paxe: AES-256-GCM unavailable on this host: " .. tostring(init_err),
      function() end)
    return
  end

  local NODE_A, NODE_B, EPOCH, CHAN = 100, 200, 3, 137
  local KEY = string.rep("\x42", 32)
  local KEY2 = string.rep("\x99", 32)
  local OPAQUE = "lunet.paxe: frame rejected"

  local RX_REASONS = {
    "rx_plaintext", "rx_short", "rx_bad_flags", "rx_len_mismatch",
    "rx_no_peer", "rx_no_epoch", "rx_auth_fail",
  }

  before_each(function()
    paxe.shutdown()
    assert(paxe.init())
    assert(paxe.set_local_id(NODE_A))
    paxe.set_fail_policy("silent")
  end)

  -- Forget the current identity and configure afresh (shutdown makes
  -- set_local_id legal again). Counters are deliberately untouched.
  local function reconfigure(node_id)
    paxe.shutdown()
    assert(paxe.set_local_id(node_id))
  end

  -- Counter-delta helper: run fn between two stats() snapshots and
  -- return a table of per-counter differences.
  local function deltas(fn)
    local before = paxe.stats()
    fn()
    local after = paxe.stats()
    local d = {}
    for name, value in pairs(after) do
      d[name] = value - before[name]
    end
    return d
  end

  -- Seal `payload` as node A for node B under EPOCH (installed here so
  -- the frame carries exactly that epoch), then become B holding A's
  -- key. Robust to the current identity: it reconfigures both ends
  -- itself. Returns the frame, ready for paxe.open assertions.
  local function seal_as_a_for_b(payload, channel)
    reconfigure(NODE_A)
    assert(paxe.keystore_set(NODE_B, EPOCH, KEY))
    local frame = assert(paxe.seal(payload, NODE_B, channel or CHAN))
    reconfigure(NODE_B)
    assert(paxe.keystore_set(NODE_A, EPOCH, KEY))
    return frame
  end

  -- A malformed argument must RAISE; when a needle is given the
  -- message must name its constraint (docs/PAXE.md "Error conventions").
  local function assert_raises_with(fn, needle)
    local raised, err = pcall(fn)
    assert.is_false(raised)
    assert.is_string(err)
    if needle then
      assert.is_true(err:find(needle, 1, true) ~= nil,
        ("error %q does not name the constraint %q"):format(tostring(err), needle))
    end
  end

  describe("module surface", function()
    it("exports the documented functions and numeric constants", function()
      for _, name in ipairs({
        "version", "init", "set_local_id", "keystore_set", "keystore_retire",
        "keystore_clear", "seal", "open", "shutdown", "stats", "set_fail_policy",
        "protect", "unprotect", "is_protected",
      }) do
        assert.are.equal("function", type(paxe[name]), name .. " must be a function")
      end
      for _, name in ipairs({
        "OVERHEAD_STANDARD", "OVERHEAD_DEK", "MAX_PAYLOAD_STANDARD", "MAX_PAYLOAD_DEK",
      }) do
        assert.is_number(paxe[name])
      end
      assert.is_string(paxe.version())
    end)

    it("init() is idempotent", function()
      assert.is_true(paxe.init())
      assert.is_true(paxe.init())
    end)

    it("verifies the overhead constants by MEASUREMENT, not by restated literals", function()
      assert(paxe.keystore_set(NODE_B, EPOCH, KEY))
      -- The C ABI seals standard frames at EVERY payload size, so both
      -- sides of the old 64-byte seam measure standard overhead.
      local frame63 = assert(paxe.seal(string.rep("s", 63), NODE_B, CHAN))
      assert.are.equal(63 + paxe.OVERHEAD_STANDARD, #frame63)
      local frame64 = assert(paxe.seal(string.rep("D", 64), NODE_B, CHAN))
      assert.are.equal(64 + paxe.OVERHEAD_STANDARD, #frame64)
      -- The largest legal standard payload produces exactly max + overhead.
      local frame_max = assert(paxe.seal(string.rep("x", paxe.MAX_PAYLOAD_STANDARD), NODE_B, CHAN))
      assert.are.equal(paxe.MAX_PAYLOAD_STANDARD + paxe.OVERHEAD_STANDARD, #frame_max)
      -- Both modes draw from the same datagram budget (65507), so the
      -- two max/overhead pairs must balance — a relationship, not a
      -- literal. (The DEK pair describes received fanout frames; the
      -- C ABI cannot seal them.)
      assert.are.equal(
        paxe.MAX_PAYLOAD_STANDARD + paxe.OVERHEAD_STANDARD,
        paxe.MAX_PAYLOAD_DEK + paxe.OVERHEAD_DEK)
    end)
  end)

  describe("argument validation", function()
    -- Every raise here doubles as the no-panic proof (see the header):
    -- under panic = "abort" any of these inputs reaching a Rust panic
    -- would kill the busted process, not just fail an assertion.

    it("set_local_id rejects wrong types, non-integers and out-of-range ids", function()
      assert_raises_with(function() paxe.set_local_id("100") end, "integer")
      assert_raises_with(function() paxe.set_local_id(1.5) end, "integer")
      assert_raises_with(function() paxe.set_local_id(-1) end)
      assert_raises_with(function() paxe.set_local_id(4294967296) end) -- beyond uint32 (Lua check)
      assert_raises_with(function() paxe.set_local_id(65536) end, "0-65535") -- u16 (Rust check)
      assert_raises_with(function() paxe.set_local_id(70000) end, "0-65535")
      assert_raises_with(function() paxe.set_local_id(nil) end)
    end)

    it("set_local_id accepts the u16 boundary values", function()
      reconfigure(0)
      reconfigure(65535)
    end)

    it("set_local_id raises on a second call without shutdown", function()
      assert_raises_with(function() paxe.set_local_id(NODE_B) end, "already configured")
    end)

    it("keystore_set rejects bad peers, epochs and keys", function()
      assert_raises_with(function() paxe.keystore_set("x", EPOCH, KEY) end, "integer")
      assert_raises_with(function() paxe.keystore_set(70000, EPOCH, KEY) end, "0-65535")
      assert_raises_with(function() paxe.keystore_set(NODE_B, 1.5, KEY) end, "integer")
      assert_raises_with(function() paxe.keystore_set(NODE_B, 32, KEY) end, "0-31")
      assert_raises_with(function() paxe.keystore_set(NODE_B, -1, KEY) end)
      assert_raises_with(function() paxe.keystore_set(NODE_B, EPOCH, 42) end, "string expected")
      assert_raises_with(function() paxe.keystore_set(NODE_B, EPOCH, KEY:sub(1, 31)) end,
        "exactly 32 bytes")
      assert_raises_with(function() paxe.keystore_set(NODE_B, EPOCH, KEY .. "\0") end,
        "exactly 32 bytes")
    end)

    it("keystore_set accepts the epoch boundaries 0 and 31", function()
      assert.is_true(paxe.keystore_set(NODE_B, 0, KEY))
      assert.is_true(paxe.keystore_set(NODE_B, 31, KEY))
    end)

    it("keystore_retire rejects bad peers and epochs", function()
      assert_raises_with(function() paxe.keystore_retire("x", EPOCH) end, "integer")
      assert_raises_with(function() paxe.keystore_retire(70000, EPOCH) end, "0-65535")
      assert_raises_with(function() paxe.keystore_retire(NODE_B, 31.5) end, "integer")
      assert_raises_with(function() paxe.keystore_retire(NODE_B, 32) end, "0-31")
    end)

    it("seal rejects bad payloads and destinations", function()
      assert_raises_with(function() paxe.seal(nil, NODE_B, CHAN) end, "string expected")
      assert_raises_with(function() paxe.seal(42, NODE_B, CHAN) end, "string expected")
      assert_raises_with(function() paxe.seal({}, NODE_B, CHAN) end, "string expected")
      assert_raises_with(function() paxe.seal("x", "200", CHAN) end, "integer")
      assert_raises_with(function() paxe.seal("x", -1, CHAN) end)
      assert_raises_with(function() paxe.seal("x", 4294967296, CHAN) end)
      assert_raises_with(function() paxe.seal("x", 65536, CHAN) end, "0-65535")
    end)

    it("seal rejects reserved and out-of-range channels", function()
      assert(paxe.keystore_set(NODE_B, EPOCH, KEY))
      for _, reserved in ipairs({ 1, 50, 99 }) do
        assert_raises_with(function() paxe.seal("x", NODE_B, reserved) end, "reserved")
      end
      assert_raises_with(function() paxe.seal("x", NODE_B, 65536) end, "0-65535")
      assert_raises_with(function() paxe.seal("x", NODE_B, "137") end, "integer")
      assert_raises_with(function() paxe.seal("x", NODE_B, 1.5) end, "integer")
    end)

    it("seal accepts channels 0, 100 and 65535 (0 is permitted; 1-99 reserved)", function()
      assert(paxe.keystore_set(NODE_B, EPOCH, KEY))
      for _, channel in ipairs({ 0, 100, 65535 }) do
        assert.is_string(paxe.seal("channel boundary", NODE_B, channel))
      end
    end)

    it("open rejects non-string frames", function()
      assert_raises_with(function() paxe.open(nil) end, "string expected")
      assert_raises_with(function() paxe.open(42) end, "string expected")
      assert_raises_with(function() paxe.open({}) end, "string expected")
    end)
  end)

  describe("operational failures (nil, message — never a raise)", function()
    it("seal before set_local_id returns nil, message", function()
      paxe.shutdown()
      local frame, err = paxe.seal("hello", NODE_B, CHAN)
      assert.is_nil(frame)
      assert.is_string(err)
    end)

    it("keystore_set / keystore_retire before set_local_id return nil, message", function()
      paxe.shutdown()
      local ok_set, err_set = paxe.keystore_set(NODE_B, EPOCH, KEY)
      assert.is_nil(ok_set)
      assert.is_string(err_set)
      local ok_retire, err_retire = paxe.keystore_retire(NODE_B, EPOCH)
      assert.is_nil(ok_retire)
      assert.is_string(err_retire)
    end)

    it("seal to an unknown peer returns nil, message naming the condition", function()
      local frame, err = paxe.seal("x", 300, CHAN)
      assert.is_nil(frame)
      assert.is_string(err)
      assert.is_true(err:find("no key installed", 1, true) ~= nil)
    end)

    it("an oversized payload returns nil, message naming the standard maximum and moves tx_oversize", function()
      assert(paxe.keystore_set(NODE_B, EPOCH, KEY))
      local frame, err
      local d = deltas(function()
        frame, err = paxe.seal(string.rep("x", paxe.MAX_PAYLOAD_STANDARD + 1), NODE_B, CHAN)
      end)
      assert.is_nil(frame)
      assert.is_string(err)
      assert.is_true(err:find(tostring(paxe.MAX_PAYLOAD_STANDARD), 1, true) ~= nil)
      assert.are.equal(1, d.tx_oversize)
      assert.are.equal(0, d.tx_total)
    end)
  end)

  describe("return shapes", function()
    it("open yields payload, from_id, channel and mode (standard)", function()
      local payload = string.rep("s", 40)
      local frame = seal_as_a_for_b(payload)
      local plain, from_id, channel, mode = paxe.open(frame)
      assert.are.equal(payload, plain)
      assert.are.equal(NODE_A, from_id)
      assert.are.equal(CHAN, channel)
      assert.are.equal("standard", mode)
    end)

    -- No DEK-frame open shape is pinned here: the C ABI cannot seal a
    -- reusable-DEK frame (fanout sealing is Rust API-only), so the
    -- open-side DEK dispatch — including mode == "dek" reporting — is
    -- pinned by the crate's own suite against a Rust-sealed frame.

    it("keystore_retire returns true for a live slot and false for an absent one", function()
      assert(paxe.keystore_set(NODE_B, EPOCH, KEY))
      assert.is_true(paxe.keystore_retire(NODE_B, EPOCH))
      assert.is_false(paxe.keystore_retire(NODE_B, EPOCH))
    end)

    it("stats() returns the 13 documented counters, all numbers", function()
      local s = paxe.stats()
      assert.are.equal("table", type(s))
      local fields = {
        "rx_total", "rx_ok",
        "rx_plaintext", "rx_short", "rx_bad_flags", "rx_len_mismatch",
        "rx_no_peer", "rx_no_epoch", "rx_auth_fail",
        "tx_total", "tx_standard", "tx_dek", "tx_oversize",
      }
      for _, name in ipairs(fields) do
        assert.is_number(s[name], name .. " must be a number")
      end
    end)
  end)

  describe("round trips through the binding", function()
    it("round-trips the empty payload (length-delimited, not NUL-terminated)", function()
      local frame = seal_as_a_for_b("")
      assert.are.equal(paxe.OVERHEAD_STANDARD, #frame)
      local plain, _, _, mode = paxe.open(frame)
      assert.are.equal("", plain)
      assert.are.equal("standard", mode)
    end)

    it("round-trips embedded NUL bytes byte-exactly", function()
      local payload = "\0a\0\0b\0c\0\0"
      local frame = seal_as_a_for_b(payload)
      local plain = paxe.open(frame)
      assert.are.equal(payload, plain)
      assert.are.equal(#payload, #plain)
    end)

    it("round-trips high bytes (0x80-0xFF) byte-exactly", function()
      local bytes = {}
      for b = 128, 255 do bytes[#bytes + 1] = string.char(b) end
      local payload = table.concat(bytes)
      local frame = seal_as_a_for_b(payload)
      local plain = paxe.open(frame)
      assert.are.equal(payload, plain)
    end)

    it("seals standard at 63, 64 and 65 bytes (there is no size-based mode boundary)", function()
      for _, size in ipairs({ 63, 64, 65 }) do
        local payload = string.rep("m", size)
        local frame = seal_as_a_for_b(payload)
        local plain, _, _, mode = paxe.open(frame)
        assert.are.equal(payload, plain)
        assert.are.equal("standard", mode)
        assert.are.equal(size + paxe.OVERHEAD_STANDARD, #frame)
        assert.are.equal(0, frame:byte(9) % 2) -- DEK flag clear at every size
      end
    end)

    it("counts each successful open exactly once (rx_total and rx_ok)", function()
      local frame = seal_as_a_for_b("counted")
      local d = deltas(function()
        assert(paxe.open(frame))
      end)
      assert.are.equal(1, d.rx_total)
      assert.are.equal(1, d.rx_ok)
    end)

    it("counts sealed frames as standard (tx_dek moves only for Rust-host fanout)", function()
      assert(paxe.keystore_set(NODE_B, EPOCH, KEY))
      local d = deltas(function()
        assert(paxe.seal("small", NODE_B, CHAN))              -- standard
        assert(paxe.seal(string.rep("x", 64), NODE_B, CHAN))  -- standard too
      end)
      assert.are.equal(2, d.tx_total)
      assert.are.equal(2, d.tx_standard)
      assert.are.equal(0, d.tx_dek)
    end)
  end)

  describe("key lifecycle from Lua", function()
    it("seals under the NEWEST installed epoch and falls back when it is retired", function()
      assert(paxe.keystore_set(NODE_B, 3, KEY))
      local frame3 = assert(paxe.seal("rotation", NODE_B, CHAN))
      assert.are.equal(3, math.floor(frame3:byte(9) / 8)) -- flags bits 3-7
      assert(paxe.keystore_set(NODE_B, 6, KEY))
      local frame6 = assert(paxe.seal("rotation", NODE_B, CHAN))
      assert.are.equal(6, math.floor(frame6:byte(9) / 8))
      assert.is_true(paxe.keystore_retire(NODE_B, 6))
      local frame_back = assert(paxe.seal("rotation", NODE_B, CHAN))
      assert.are.equal(3, math.floor(frame_back:byte(9) / 8))
    end)

    it("a frame sealed under a retired epoch fails with rx_no_epoch, NOT rx_no_peer", function()
      local frame = seal_as_a_for_b("epoch three")
      -- The peer stays provisioned (epoch 4 remains), so the miss is a
      -- ROTATION problem, not a topology one.
      assert(paxe.keystore_set(NODE_A, 4, KEY))
      assert.is_true(paxe.keystore_retire(NODE_A, EPOCH))
      local plain, err
      local d = deltas(function()
        plain, err = paxe.open(frame)
      end)
      assert.is_nil(plain)
      assert.are.equal(OPAQUE, err)
      assert.are.equal(1, d.rx_no_epoch)
      assert.are.equal(0, d.rx_no_peer)
      assert.are.equal(0, d.rx_ok)
    end)

    it("after keystore_clear the same frame fails with rx_no_peer, NOT rx_no_epoch", function()
      local frame = seal_as_a_for_b("cleared")
      assert.is_true(paxe.keystore_clear())
      local plain, err
      local d = deltas(function()
        plain, err = paxe.open(frame)
      end)
      assert.is_nil(plain)
      assert.are.equal(OPAQUE, err)
      assert.are.equal(1, d.rx_no_peer)
      assert.are.equal(0, d.rx_no_epoch)
    end)

    it("overwriting an occupied slot erases the old key", function()
      assert(paxe.keystore_set(NODE_B, EPOCH, KEY))
      assert.is_true(paxe.keystore_set(NODE_B, EPOCH, KEY2)) -- overwrite same slot
      local frame = assert(paxe.seal("overwritten", NODE_B, CHAN))
      -- A receiver still holding the OLD key gets an opaque auth failure.
      reconfigure(NODE_B)
      assert(paxe.keystore_set(NODE_A, EPOCH, KEY))
      local d = deltas(function()
        local plain, err = paxe.open(frame)
        assert.is_nil(plain)
        assert.are.equal(OPAQUE, err)
      end)
      assert.are.equal(1, d.rx_auth_fail)
      -- A receiver holding the NEW key opens it.
      reconfigure(NODE_B)
      assert(paxe.keystore_set(NODE_A, EPOCH, KEY2))
      assert.are.equal("overwritten", (paxe.open(frame)))
    end)

    it("keystore_clear erases every installed key", function()
      assert(paxe.keystore_set(NODE_B, 0, KEY))
      assert(paxe.keystore_set(NODE_B, 31, KEY))
      assert.is_true(paxe.keystore_clear())
      local frame, err = paxe.seal("x", NODE_B, CHAN)
      assert.is_nil(frame)
      assert.is_string(err)
    end)

    it("shutdown is idempotent and set_local_id may configure afresh", function()
      paxe.shutdown()
      paxe.shutdown()
      assert(paxe.set_local_id(NODE_B))
      local frame, err = paxe.seal("x", NODE_A, CHAN) -- no key for A here
      assert.is_nil(frame)
      assert.is_string(err)
    end)
  end)

  describe("opaque rejection (no decryption oracle)", function()
    it("collapses EVERY frame-level failure to nil plus the ONE generic message", function()
      local frame = seal_as_a_for_b("uniform")
      local corrupted = frame:sub(1, 29) .. string.char(bit.bxor(frame:byte(30), 1)) .. frame:sub(31)
      local causes = {
        corrupted,                                  -- authentication failure
        frame:sub(1, #frame - 1),                   -- truncated
        string.rep("\0", 37),                       -- flags constant-bit violation
        "1234",                                     -- too short
        "",                                         -- empty
      }
      local message
      for _, bad in ipairs(causes) do
        local plain, err = paxe.open(bad)
        assert.is_nil(plain)
        assert.is_string(err)
        if message then
          assert.are.equal(message, err) -- the SAME message for every cause
        else
          message = err
        end
      end
      assert.are.equal(OPAQUE, message) -- the documented generic message
      -- Even an UNCONFIGURED receiver collapses to the same result.
      paxe.shutdown()
      local plain_unconf, err_unconf = paxe.open(frame)
      assert.is_nil(plain_unconf)
      assert.are.equal(message, err_unconf)
    end)

    it("reveals the rejection reason ONLY through counter deltas", function()
      local frame = seal_as_a_for_b("typed")
      local corrupted = frame:sub(1, 29) .. string.char(bit.bxor(frame:byte(30), 1)) .. frame:sub(31)
      local function assert_one_reason(bad_frame, counter)
        local d = deltas(function()
          local plain, err = paxe.open(bad_frame)
          assert.is_nil(plain)
          assert.are.equal(OPAQUE, err)
        end)
        assert.are.equal(1, d.rx_total)
        assert.are.equal(0, d.rx_ok)
        for _, name in ipairs(RX_REASONS) do
          assert.are.equal(name == counter and 1 or 0, d[name],
            name .. " moved for a " .. counter .. " trigger")
        end
      end
      assert_one_reason(corrupted, "rx_auth_fail")
      assert_one_reason(frame:sub(1, #frame - 1), "rx_len_mismatch")
      assert_one_reason(string.rep("\0", 37), "rx_bad_flags")
      assert_one_reason("1234", "rx_short")
      -- A 37-byte frame carrying the DEK bit: under the 97-byte
      -- reusable-DEK minimum, counted as short (the parse-geometry
      -- gate). The DEK flag's constant bits must be valid (0x1D: DEK
      -- set, bit 1 clear, bit 2 set) or the flags gate fires first.
      assert_one_reason(string.rep("\0", 8) .. string.char(0x1D) .. string.rep("\0", 28),
        "rx_short")
      -- The reusable-DEK receive geometry (authenticated envelope, no
      -- inner Length field — a length disagreement counts as
      -- rx_len_mismatch, there is no separate counter) is exercised in
      -- the crate's suite: the C ABI cannot seal a DEK frame to forge
      -- here.
    end)

    it("a frame presented to an UNCONFIGURED receiver is dropped but not counted", function()
      local frame = seal_as_a_for_b("uncounted")
      paxe.shutdown()
      local d = deltas(function()
        local plain, err = paxe.open(frame)
        assert.is_nil(plain)
        assert.are.equal(OPAQUE, err)
      end)
      assert.are.equal(0, d.rx_total)
      assert.are.equal(0, d.rx_ok)
    end)

    it("keeps the invariant rx_total == rx_ok + sum(reject reasons) across a mixed window", function()
      local good = seal_as_a_for_b("invariant")
      local corrupted = good:sub(1, 29) .. string.char(bit.bxor(good:byte(30), 1)) .. good:sub(31)
      local d = deltas(function()
        assert(paxe.open(good))           -- opens
        paxe.open(corrupted)              -- auth failure
        paxe.open(string.rep("\0", 37))   -- bad flags
        paxe.open("1234")                 -- short
      end)
      assert.are.equal(4, d.rx_total)
      assert.are.equal(1, d.rx_ok)
      local reject_sum = 0
      for _, name in ipairs(RX_REASONS) do
        reject_sum = reject_sum + d[name]
      end
      assert.are.equal(3, reject_sum)
      assert.are.equal(d.rx_total, d.rx_ok + reject_sum)
    end)
  end)

  describe("failure policy selection", function()
    -- The policy's stderr behaviour (silent / log_once / verbose [PAXE]
    -- lines) is deliberately NOT tested here: it requires capturing a
    -- C-level fprintf, which busted cannot intercept — its home is the
    -- the smoke test's subprocess wiring. Only the selection API is pinned.
    it("accepts the documented spellings case-insensitively", function()
      assert.is_true(paxe.set_fail_policy("silent"))
      assert.is_true(paxe.set_fail_policy("log_once"))
      assert.is_true(paxe.set_fail_policy("verbose"))
      assert.is_true(paxe.set_fail_policy("SILENT"))
      assert.is_true(paxe.set_fail_policy("Log_Once"))
      assert.is_true(paxe.set_fail_policy("VERBOSE"))
    end)

    it("returns false (never raises) for unknown spellings and non-strings", function()
      assert.is_false(paxe.set_fail_policy("loud"))
      assert.is_false(paxe.set_fail_policy(""))
      assert.is_false(paxe.set_fail_policy(42))
      assert.is_false(paxe.set_fail_policy(nil))
      assert.is_false(paxe.set_fail_policy({}))
    end)
  end)

  describe("protect/unprotect/is_protected", function()
    -- The full protected-socket lifecycle — protect() succeeding,
    -- is_protected() reflecting it, sealed send and gated recv — needs
    -- the lunet runtime (a lunet.udp module and a bound socket handle
    -- from a running loop), which does not exist inside busted. That
    -- end-to-end coverage is test/run_paxe_udp_e2e.sh's. What IS pinned here: every
    -- validation raise (all of which fire before the udp module is
    -- touched) and the registration-free behaviour of is_protected /
    -- unprotect. io.stdout serves as a userdata handle stand-in; none
    -- of these calls may dereference it.

    it("rejects a non-userdata socket and a non-table config", function()
      assert_raises_with(function() paxe.protect("not-a-socket", { peer = NODE_B }) end,
        "udp handle expected")
      assert_raises_with(function() paxe.protect(nil, { peer = NODE_B }) end,
        "udp handle expected")
      assert_raises_with(function() paxe.protect(io.stdout, "not-a-table") end,
        "table expected")
      assert_raises_with(function() paxe.protect(io.stdout, nil) end, "table expected")
    end)

    it("rejects bad config.peer and reserved or out-of-range config.channel", function()
      assert_raises_with(function() paxe.protect(io.stdout, {}) end, "config.peer")
      assert_raises_with(function() paxe.protect(io.stdout, { peer = "x" }) end, "config.peer")
      assert_raises_with(function() paxe.protect(io.stdout, { peer = 70000 }) end, "config.peer")
      assert_raises_with(function() paxe.protect(io.stdout, { peer = NODE_B, channel = 1 }) end,
        "reserved")
      assert_raises_with(function() paxe.protect(io.stdout, { peer = NODE_B, channel = 99 }) end,
        "reserved")
      assert_raises_with(function() paxe.protect(io.stdout, { peer = NODE_B, channel = 70000 }) end,
        "config.channel")
      assert_raises_with(function() paxe.protect(io.stdout, { peer = NODE_B, channel = "x" }) end,
        "config.channel")
    end)

    it("raises when the module is not configured (set_local_id first)", function()
      paxe.shutdown()
      assert_raises_with(function() paxe.protect(io.stdout, { peer = NODE_B }) end,
        "set_local_id")
    end)

    it("is_protected is false for an unregistered handle; unprotect is idempotent", function()
      assert.is_false(paxe.is_protected(io.stdout))
      assert.is_true(paxe.unprotect(io.stdout))
      assert.is_false(paxe.is_protected(io.stdout))
      -- Unprotecting a handle that was never protected is not an error.
      assert.is_true(paxe.unprotect(io.stdout))
    end)
  end)
end)
