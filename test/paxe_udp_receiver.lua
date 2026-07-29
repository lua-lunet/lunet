-- item09 end-to-end test, RECEIVER side (PAXE node 200). Driven by
-- test/run_paxe_udp_e2e.sh together with test/paxe_udp_sender.lua
-- (node 100) — two processes because the Rust keystore holds ONE node
-- identity per process.
--
-- Sequence: protect() validation, the protect/unprotect toggle (proving
-- the switch genuinely controls behaviour, both ways), the NEGATIVE
-- tests first (unencrypted and forged datagrams to the protected socket,
-- including plaintext crafted so its wire byte 8 PASSES the flags
-- constant-bit gate — the explicit addressing check must be what drops
-- it), then the positive round-trip: one sealed frame from node 100
-- arrives as plaintext + authenticated fromId + channel.
--
-- Loopback only (127.0.0.1), per the repository security rule.

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ext_dir = script_dir .. "/../ext/paxe"

local chunk, load_err = loadfile(ext_dir .. "/paxe.lua")
if not chunk then error("cannot load paxe.lua: " .. tostring(load_err)) end
local paxe = chunk()
local lunet = require("lunet")
local udp = require("lunet.udp")

local e2e_dir = os.getenv("LUNET_PAXE_E2E_DIR") or ".tmp/paxe-e2e"

local failures = 0
local checks = 0
local lines = {}

local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    lines[#lines + 1] = "FAIL: " .. msg
    print("FAIL: " .. msg)
  else
    lines[#lines + 1] = "OK: " .. msg
    print("   OK: " .. msg)
  end
end

local function check_raises(fn, needle, msg)
  checks = checks + 1
  local ok, err = pcall(fn)
  if ok then
    failures = failures + 1
    lines[#lines + 1] = "FAIL: " .. msg .. " (did not raise)"
    print("FAIL: " .. msg .. " (did not raise)")
  elseif needle and not tostring(err):find(needle, 1, true) then
    failures = failures + 1
    lines[#lines + 1] = "FAIL: " .. msg .. " (raised '" .. tostring(err) .. "')"
    print("FAIL: " .. msg .. " (raised '" .. tostring(err) .. "')")
  else
    lines[#lines + 1] = "OK: " .. msg
    print("   OK: " .. msg)
  end
end

local KEY = string.rep("\x42", 32)
local NODE_A, NODE_B, CHAN = 100, 200, 137
local PORT_B, PORT_RAW, PORT_A = 20411, 20413, 20412

-- lunet's udp API is coroutine-only (lunet_ensure_coroutine): the whole
-- body runs inside lunet.spawn, the same pattern as test/udp_echo.lua.
local function main()
  print("=== paxe udp e2e: receiver (node 200) ===")

  local init_ok, init_err = paxe.init()
  if not init_ok then
    print("SKIP: AES-256-GCM unavailable on this host: " .. tostring(init_err))
    os.exit(0)
  end

  local sockB, berr = udp.bind("127.0.0.1", PORT_B)
  assert(sockB, berr)
  local raw, rerr = udp.bind("127.0.0.1", PORT_RAW)
  assert(raw, rerr)

  -- protect() fail-fast validation (raises = bug in the calling script).
  check_raises(function() paxe.protect(sockB, { peer = NODE_A, channel = CHAN }) end,
    "set_local_id", "protect before set_local_id raises (no silent dead socket)")
  assert(paxe.set_local_id(NODE_B))
  assert(paxe.keystore_set(NODE_A, 3, KEY))
  check_raises(function() paxe.protect(sockB, {}) end, "config.peer", "missing peer raises")
  check_raises(function() paxe.protect(sockB, { peer = 70000 }) end, "65535", "out-of-range peer raises")
  check_raises(function() paxe.protect(sockB, { peer = NODE_A, channel = 42 }) end,
    "reserved", "reserved channel raises")

  -- The toggle, BOTH ways. First arm it.
  check(paxe.protect(sockB, { peer = NODE_A, channel = CHAN }) == true, "protect(sockB)")
  local prot, ppeer, pchan = paxe.is_protected(sockB)
  check(prot == true and ppeer == NODE_A and pchan == CHAN, "is_protected reports peer and channel")

  -- Disarm: an unencrypted datagram must now pass through RAW. This is
  -- the proof that protect genuinely controls behaviour — the old
  -- module's set_enabled printed "enabled" and changed nothing.
  check(paxe.unprotect(sockB) == true and paxe.is_protected(sockB) == false,
    "unprotect toggles protection off")
  local control = "control: socket currently unprotected"
  assert(udp.send(raw, "127.0.0.1", PORT_B, control))
  local cdata, chost, cport, cfrom, cchan = udp.recv(sockB)
  check(cdata == control and chost == "127.0.0.1" and cport == PORT_RAW,
    "unprotected recv passes datagrams through raw")
  check(cfrom == nil and cchan == nil, "unprotected recv carries no fromId/channel")

  -- Re-arm for the real test. Channel omitted once to pin the default.
  check(paxe.protect(sockB, { peer = NODE_A }) == true, "re-protect without channel")
  local prot2, _, dchan = paxe.is_protected(sockB)
  check(prot2 == true and dchan == 0, "default channel is 0")
  check(paxe.protect(sockB, { peer = NODE_A, channel = CHAN }) == true, "protect with channel 137")

  -- ── NEGATIVE TESTS FIRST ────────────────────────────────────────────
  local s0 = paxe.stats()

  -- (1) THE crafted case: plaintext whose wire byte 8 (Lua index 9) is
  -- 0x04 — it PASSES the flags constant-bit gate — but whose toId
  -- (bytes 3-4) is 9999, not this node. The explicit addressing check
  -- must drop it, and rx_plaintext — NOT rx_bad_flags — must move.
  local crafted_flags_pass = string.char(0x00, 0x64, 0x27, 0x0F, 0x00, 0x89, 0x00, 0x0A, 0x04)
    .. string.rep("P", 20)
  -- (2) Plain ASCII text with no structure at all.
  local plain_ascii = "hello, this datagram was never encrypted"
  -- (3) Control: a datagram that DOES present a PAXE prefix addressed to
  -- this node (toId = 200) but fails the flags gate (0x00) — it must
  -- reach open() and move rx_bad_flags, NOT rx_plaintext.
  local crafted_to_us_bad_flags = string.char(0x00, 0x64, 0x00, 0xC8, 0x00, 0x89, 0x00, 0x05, 0x00)
    .. string.rep("Q", 31)

  assert(udp.send(raw, "127.0.0.1", PORT_B, crafted_flags_pass))
  assert(udp.send(raw, "127.0.0.1", PORT_B, plain_ascii))
  assert(udp.send(raw, "127.0.0.1", PORT_B, crafted_to_us_bad_flags))

  -- Signal the sender, then block: the three bad datagrams sit AHEAD of
  -- node A's frame in arrival order, so if any of them were delivered,
  -- recv would return it instead of the protected payload.
  local f = assert(io.open(e2e_dir .. "/ready", "w"))
  f:write("ready\n")
  f:close()

  local data, host, port, from_id, channel = udp.recv(sockB)

  check(data == "hello paxe",
    "protected payload received byte-exactly (the three bad datagrams never reached Lua)")
  check(from_id == NODE_A, "authenticated fromId is 100 (genuinely different node id)")
  check(channel == CHAN, "authenticated channel is 137")
  check(host == "127.0.0.1" and port == PORT_A, "transport tuple is the sender's address")

  local s1 = paxe.stats()
  check(s1.rx_plaintext == s0.rx_plaintext + 2,
    "rx_plaintext +2: both unencrypted datagrams dropped by the explicit gate")
  check(s1.rx_bad_flags == s0.rx_bad_flags + 1,
    "rx_bad_flags +1: the addressed-to-us flags forgery attributed correctly")
  check(s1.rx_ok == s0.rx_ok + 1, "rx_ok +1")
  check(s1.rx_total == s0.rx_total + 4, "rx_total +4 (2 plaintext + 1 bad flags + 1 ok)")

  -- close() must also clear the protection entry (pointer-reuse safety).
  assert(udp.close(sockB))
  check(paxe.is_protected(sockB) == false, "close removed the protection entry")
  assert(udp.close(raw))

  paxe.shutdown()

  local rf = assert(io.open(e2e_dir .. "/result", "w"))
  if failures > 0 then
    rf:write("FAIL: " .. failures .. " of " .. checks .. " receiver checks failed\n")
  else
    rf:write("PASS: all " .. checks .. " receiver checks passed\n")
  end
  for _, l in ipairs(lines) do rf:write(l .. "\n") end
  rf:close()

  print(failures > 0 and ("=== receiver: " .. failures .. " FAILURES ===")
    or ("=== receiver: all " .. checks .. " checks passed ==="))
  os.exit(failures > 0 and 1 or 0)
end

lunet.spawn(main)
