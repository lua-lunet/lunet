-- Smoke test for the lunet.paxe extension (item07 Lua-facing API).
--
-- Before running, build the Rust extension:
--   (cd ext/paxe && cargo build --release)
-- Then run:
--   lunet-run test/smoke_paxe.lua
-- (or: LUNET_PAXE_LIB=ext/paxe/target/release/liblunet_paxe.dylib luajit test/smoke_paxe.lua)
--
-- Covers: module load, constants by measurement, init, set_local_id,
-- keystore_set/retire/clear, seal/open round-trips across TWO DIFFERENT
-- node ids, the 63/64-byte mode boundary, malformed arguments RAISING
-- (never crashing), and the opaque open() failure: a corrupted frame
-- returns nil plus ONE generic message — never a reason-revealing one.

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ext_dir = script_dir .. "/../ext/paxe"

local function load_paxe()
  local chunk, err = loadfile(ext_dir .. "/paxe.lua")
  if not chunk then error("cannot load paxe.lua: " .. tostring(err)) end
  return chunk()
end

local failures = 0
local checks = 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. msg)
  else
    print(("   OK (%d): %s"):format(checks, msg))
  end
end

-- Malformed arguments must RAISE a Lua error — and the process must
-- survive (under panic = "abort" a Rust panic would kill it outright).
local function check_raises(fn, needle, msg)
  checks = checks + 1
  local ok, err = pcall(fn)
  if ok then
    failures = failures + 1
    print("FAIL: " .. msg .. " (did not raise)")
  elseif needle and not tostring(err):find(needle, 1, true) then
    failures = failures + 1
    print("FAIL: " .. msg .. " (raised '" .. tostring(err) .. "', expected '" .. needle .. "')")
  else
    print(("   OK (%d): %s"):format(checks, msg))
  end
end

local function main()
  print("=== lunet.paxe smoke test (item07) ===")
  print()

  print("1. Loading lunet.paxe ...")
  local ok, paxe = pcall(load_paxe)
  if not ok then
    print("FAIL: " .. tostring(paxe))
    os.exit(1)
  end
  print("   OK: module loaded, version " .. paxe.version())

  -- Constants: documented protocol values, derived from the Rust codec.
  check(paxe.OVERHEAD_STANDARD == 37, "OVERHEAD_STANDARD == 37")
  check(paxe.OVERHEAD_DEK == 83, "OVERHEAD_DEK == 83")
  check(paxe.MAX_PAYLOAD_STANDARD == 65470, "MAX_PAYLOAD_STANDARD == 65470")
  check(paxe.MAX_PAYLOAD_DEK == 65424, "MAX_PAYLOAD_DEK == 65424")

  -- init: on a host without the AES-GCM hardware path this is a clean
  -- skip (environment property, same gate as CI), not a failure.
  local init_ok, init_err = paxe.init()
  if not init_ok then
    print("SKIP: AES-256-GCM unavailable on this host: " .. tostring(init_err))
    os.exit(0)
  end
  check(init_ok == true, "init()")
  check(paxe.init() == true, "init() is idempotent")

  -- Operational failure BEFORE configuration: nil + message, not a raise.
  local frame, seal_err = paxe.seal("hello", 200, 137)
  check(frame == nil and type(seal_err) == "string" and seal_err:find("set_local_id", 1, true) ~= nil,
    "seal before set_local_id returns nil + message")

  local KEY = string.rep("\x42", 32)
  local NODE_A, NODE_B, CHAN = 100, 200, 137

  check(paxe.set_local_id(NODE_A) == true, "set_local_id(100)")

  -- ── Malformed arguments RAISE (each message names its constraint) ────────
  check_raises(function() paxe.set_local_id(70000) end, "0-65535", "node id out of u16 range raises")
  check_raises(function() paxe.set_local_id("x") end, "integer", "non-number node id raises")
  check_raises(function() paxe.set_local_id(1.5) end, "integer", "non-integer node id raises")
  check_raises(function() paxe.set_local_id(NODE_B) end, "already configured", "second set_local_id raises")
  check_raises(function() paxe.keystore_set(NODE_B, 32, KEY) end, "0-31", "epoch above 31 raises")
  check_raises(function() paxe.keystore_set(NODE_B, 0, "short") end, "exactly 32 bytes", "short key raises")
  check_raises(function() paxe.keystore_set(NODE_B, 0, KEY .. "\0") end, "exactly 32 bytes", "long key raises")
  check_raises(function() paxe.keystore_set(70000, 0, KEY) end, "0-65535", "peer out of range raises")
  check_raises(function() paxe.seal("x", NODE_B, 99) end, "reserved", "reserved channel 99 raises")
  check_raises(function() paxe.seal("x", NODE_B, 1) end, "reserved", "reserved channel 1 raises")
  check_raises(function() paxe.seal("x", NODE_B, 65536) end, "0-65535", "channel out of range raises")
  check_raises(function() paxe.seal(42, NODE_B, CHAN) end, "string expected", "non-string payload raises")
  check_raises(function() paxe.open(nil) end, "string expected", "non-string frame raises")
  check_raises(function() paxe.keystore_retire(NODE_B, 31.5) end, "integer", "non-integer epoch raises")

  -- ── Keys and seal as node A ─────────────────────────────────────────────
  check(paxe.keystore_set(NODE_B, 3, KEY) == true, "keystore_set(200, 3, key)")

  -- 63-byte payload: standard mode, frame is EXACTLY payload + overhead
  -- (the constants verified by measurement, not by restating literals).
  local payload63 = string.rep("s", 63)
  local frame63 = assert(paxe.seal(payload63, NODE_B, CHAN))
  check(#frame63 == #payload63 + paxe.OVERHEAD_STANDARD,
    "#seal(63-byte) == 63 + OVERHEAD_STANDARD")
  check(frame63:byte(9) % 2 == 0, "63-byte payload seals standard (flags bit 0 clear)")
  check(math.floor(frame63:byte(9) / 8) == 3, "wire flags carry the send epoch (3)")

  -- 64-byte payload: DEK mode.
  local payload64 = string.rep("D", 64)
  local frame64 = assert(paxe.seal(payload64, NODE_B, CHAN))
  check(#frame64 == #payload64 + paxe.OVERHEAD_DEK,
    "#seal(64-byte) == 64 + OVERHEAD_DEK")
  check(frame64:byte(9) % 2 == 1, "64-byte payload seals DEK (flags bit 0 set)")

  -- Send epoch follows the NEWEST installed epoch (rotation procedure).
  check(paxe.keystore_set(NODE_B, 6, KEY) == true, "keystore_set(200, 6, key)")
  local f_rot = assert(paxe.seal(payload63, NODE_B, CHAN))
  check(math.floor(f_rot:byte(9) / 8) == 6, "seal uses the newest installed epoch (6)")
  check(paxe.keystore_retire(NODE_B, 6) == true, "keystore_retire(200, 6) retires a live slot")
  check(paxe.keystore_retire(NODE_B, 6) == false, "keystore_retire of an absent slot returns false")
  local f_back = assert(paxe.seal(payload63, NODE_B, CHAN))
  check(math.floor(f_back:byte(9) / 8) == 3, "seal falls back to epoch 3 after retiring 6")

  -- Seal to an unknown peer: operational failure.
  local no_frame, no_err = paxe.seal(payload63, 300, CHAN)
  check(no_frame == nil and type(no_err) == "string" and no_err:find("no key installed", 1, true) ~= nil,
    "seal to an unknown peer returns nil + 'no key installed'")

  -- Oversize payload: operational failure naming the DEK maximum.
  local big_frame, big_err = paxe.seal(string.rep("x", paxe.MAX_PAYLOAD_DEK + 1), NODE_B, CHAN)
  check(big_frame == nil and type(big_err) == "string" and big_err:find("65424", 1, true) ~= nil,
    "oversize payload returns nil + message naming 65424")

  -- ── Become node B and open A's frames (TWO DIFFERENT node ids) ──────────
  paxe.shutdown()
  check(paxe.set_local_id(NODE_B) == true, "shutdown(); set_local_id(200)")
  check(paxe.keystore_set(NODE_A, 3, KEY) == true, "B installs the link key under peer A")

  local plain, from_id, channel, mode = paxe.open(frame63)
  check(plain == payload63, "standard frame round-trips byte-exactly")
  check(from_id == NODE_A, "open reports the authenticated from_id (100 ~= 200)")
  check(channel == CHAN, "open reports the channel")
  check(mode == "standard", "open reports mode 'standard'")

  local plain64, from64, _, mode64 = paxe.open(frame64)
  check(plain64 == payload64 and from64 == NODE_A and mode64 == "dek",
    "DEK frame round-trips, mode 'dek'")

  -- ── Opaque open failure: ONE generic message for EVERY cause ────────────
  local corrupted = frame63:sub(1, 30) .. string.char(frame63:byte(31) ~ 1) .. frame63:sub(32)
  local p1, e1 = paxe.open(corrupted)
  local p2, e2 = paxe.open(frame63:sub(1, #frame63 - 1))         -- truncated
  local p3, e3 = paxe.open(string.rep("\0", 64))                 -- garbage flags
  local p4, e4 = paxe.open("")                                   -- empty
  local p5, e5 = paxe.open(frame64:sub(1, 37))                   -- short DEK-flag frame
  check(p1 == nil and e1 == "lunet.paxe: frame rejected", "corrupted frame: nil + the one opaque message")
  check(p2 == nil and e2 == e1 and p3 == nil and e3 == e1 and p4 == nil and e4 == e1 and p5 == nil and e5 == e1,
    "every rejection cause yields the SAME message (no decryption oracle)")
  check(not e1:find("key", 1, true) and not e1:find("auth", 1, true) and not e1:find("length", 1, true),
    "the opaque message reveals no reason")

  -- ── clear + shutdown ────────────────────────────────────────────────────
  check(paxe.keystore_clear() == true, "keystore_clear()")
  local gone, gerr = paxe.open(frame63)
  check(gone == nil and gerr == "lunet.paxe: frame rejected",
    "after keystore_clear, open is the same opaque drop")
  paxe.shutdown()
  local p6, e6 = paxe.seal("x", NODE_A, CHAN)
  check(p6 == nil and type(e6) == "string", "after shutdown, seal is an operational failure")
  check(paxe.set_local_id(NODE_A) == true, "set_local_id works after shutdown")
  paxe.shutdown()

  print()
  if failures > 0 then
    print(("=== %d of %d checks FAILED ==="):format(failures, checks))
    os.exit(1)
  end
  print(("=== All paxe smoke checks passed (%d checks) ==="):format(checks))
  os.exit(0)
end

main()
