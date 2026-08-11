-- PERMANENT end-to-end test, RECEIVER side (PAXE node 200). Driven by
-- test/run_paxe_udp_e2e.sh together with test/paxe_udp_sender.lua
-- (node 100) — two processes because the Rust keystore holds ONE node
-- identity per process. This is the permanent wire test that proves PAXE
-- protects REAL UDP traffic, kept runnable as a smoke/CI check (exit 0
-- only when every check passes).
--
-- Legs, in order (the negative leg runs FIRST — it is the security
-- contract):
--   0. protect() validation and the protect/unprotect toggle (protection
--      genuinely controls behaviour, both ways).
--   1. NEGATIVE: unencrypted datagrams to the protected socket deliver
--      NOTHING to Lua. One is crafted so its wire byte 8 (0x04) PASSES
--      the flags constant-bit gate — the EXPLICIT addressing check must
--      be what drops it: rx_plaintext moves, rx_bad_flags does NOT. A
--      forged frame addressed TO this node with byte 8 = 0x00 fails the
--      flags gate instead: rx_bad_flags moves. The two reject paths are
--      distinguished inside a window measured while recv is blocked,
--      before any valid frame exists.
--   2. PER-SOCKET INDEPENDENCE: an unencrypted datagram passes raw on
--      the unprotected socket of this same process while the protected
--      socket drops its copy (counted in the negative window).
--   3. POSITIVE: sealed frames from node 100 (a genuinely DIFFERENT node
--      id — identical ids would mask a toId-on-send vs fromId-on-receive
--      key-lookup transposition) arrive byte-exact with the
--      authenticated fromId and channel.
--   4. EVERY SIZE IS STANDARD over the wire: 63, 64 and 65-byte payloads
--      all traverse a real socket as standard frames (the C ABI has no
--      size-based mode selection).
--   5. MAX PAYLOAD: 65470 bytes (the documented standard maximum) — the
--      frame is 65507 bytes, exactly the UDP datagram limit (65535 - 20 - 8).
--      The size invariant is asserted UNCONDITIONALLY; the wire traversal
--      is discriminated by a raw 65507-byte control to the unprotected
--      socket: if the control is dropped too (macOS loopback refuses
--      datagrams > ~9216 with EMSGSIZE), the platform cannot carry it and
--      the leg is a reported platform-skip; if the control arrives but
--      the sealed frame does not, that is a GENUINE FAILURE. A
--      calculation error in the maximum shows up here and nowhere else.
--   6. CONCURRENCY: 4 receiver coroutines on 4 protected sockets against
--      4 sender coroutines, 16 distinguishable payloads; each coroutine
--      asserts it received its OWN payloads in order (crossed delivery
--      cannot hide), with each burst queued in C before draining. The
--      sockets are opened, used and closed under load (handle lifetime).
--
-- TIMEOUT INTERPRETATION: every receive is bounded by the
-- watchdog below and the runner bounds both processes. A TIMEOUT here
-- means a datagram was dropped that should not have been, or a receive
-- stalled waiting for one that never arrives — diagnose it as a lost
-- datagram or stalled receive; do not retry.
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
local PORT_MAIN, PORT_A, PORT_RAW = 20411, 20412, 20413
local CONC_N, CONC_K, CONC_PORT_BASE, CONC_CHAN_BASE = 4, 4, 20420, 300
local WATCHDOG_MS = 15000

-- Payload generators. KEEP IN SYNC with test/paxe_udp_sender.lua — the
-- wire assertions compare byte-for-byte against these exact strings.
local function mkpayload(len, tag, fill)
  local p = "PAXE14-" .. tag .. "|"
  return p .. string.rep(fill, len - #p)
end
local P63 = mkpayload(63, "B63", "s")
local P64 = mkpayload(64, "B64", "D")
local P65 = mkpayload(65, "B65", "E")
local PLARGE = mkpayload(8192, "L8192", "L")
local PMAX = (function()
  local t = {}
  for i = 0, 250 do t[#t + 1] = string.char((i * 7) % 256) end
  return string.rep(table.concat(t), 261):sub(1, paxe.MAX_PAYLOAD_STANDARD)
end)()
-- Raw control for the max-payload platform probe: exactly one maximum
-- UDP datagram (65535 - 20 - 8), sent UNENCRYPTED to the unprotected
-- socket ahead of a small marker.
local UDP_MAX = 65535 - 20 - 8
local RAW_CONTROL_LEN = UDP_MAX
local MAX_MARKER = "PAXE14-MAXRAW-DONE"
local function conc_payload(i, k)
  local p = ("PAXE14-C|i=%d|k=%d|"):format(i, k)
  return p .. string.rep(string.char(96 + i * 4 + k), 14)
end

-- Timeout machinery. `open_socks` tracks every live handle so the
-- watchdog can close them ALL on timeout: a close makes a stalled recv
-- return (nil, nil, "udp closed") instead of hanging, and the failure is
-- then reported as a timeout. After the watchdog fires it OWNS all
-- closes — everyone else must skip closing (timed_out) so no handle is
-- closed twice (a double close would be a use-after-free in udp.c).
local timed_out = false
local phases_done = false
local open_socks = {}

local function close_sock(sock)
  if timed_out then return end
  open_socks[sock] = nil
  udp.close(sock)
end

local function spawn_watchdog()
  lunet.spawn(function()
    lunet.sleep(WATCHDOG_MS)
    if phases_done then return end
    timed_out = true
    check(false, ("TIMEOUT after %d ms: a timeout means an unexpected drop or a stalled "
      .. "receive — diagnose, do not retry"):format(WATCHDOG_MS))
    for s in pairs(open_socks) do udp.close(s) end
    open_socks = {}
  end)
end

-- Run-wide state, set by main() and read by finalize(). max_wire records
-- whether the documented-max frame traversed the wire (platform permits)
-- so the run-wide counter expectations stay exact either way.
local s0, sockMain, sockRaw
local max_wire = false

local function finalize(flow_ok)
  phases_done = true
  if not timed_out then
    if flow_ok then
      local s3 = paxe.stats()
      local function d(k) return s3[k] - s0[k] end
      local pos = 4 + (max_wire and 1 or 0) -- 63/64/65/8192 (+ the max)
      check(d("rx_ok") == pos + CONC_N * CONC_K,
        ("run-wide: rx_ok delta == %d positive + 16 concurrency"):format(pos))
      check(d("rx_total") == 4 + pos + CONC_N * CONC_K,
        ("run-wide: rx_total delta == 4 negative + %d positive + 16 concurrency"):format(pos))
      local rejects = d("rx_plaintext") + d("rx_short") + d("rx_bad_flags") + d("rx_len_mismatch")
        + d("rx_no_peer") + d("rx_no_epoch") + d("rx_auth_fail")
      check(d("rx_total") == d("rx_ok") + rejects,
        "invariant over the whole run: rx_total == rx_ok + sum(all reject reasons)")
      check(d("rx_plaintext") == 3 and d("rx_bad_flags") == 1 and rejects == 4,
        "run-wide reject attribution: exactly 3 plaintext + 1 bad_flags, nothing else")
    end
    close_sock(sockMain)
    close_sock(sockRaw)
  end
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

-- lunet's udp API is coroutine-only (lunet_ensure_coroutine): the whole
-- body runs inside lunet.spawn, the same pattern as test/udp_echo.lua.
local function main()
  print("=== paxe udp e2e: receiver (node 200) ===")

  local init_ok, init_err = paxe.init()
  if not init_ok then
    print("SKIP: AES-256-GCM unavailable on this host: " .. tostring(init_err))
    os.exit(0)
  end
  spawn_watchdog()

  sockMain = assert(udp.bind("127.0.0.1", PORT_MAIN))
  sockRaw = assert(udp.bind("127.0.0.1", PORT_RAW))
  open_socks[sockMain] = true
  open_socks[sockRaw] = true

  -- ── leg 0: protect() validation and the toggle, BOTH ways ────────────
  check_raises(function() paxe.protect(sockMain, { peer = NODE_A, channel = CHAN }) end,
    "set_local_id", "protect before set_local_id raises (no silent dead socket)")
  assert(paxe.set_local_id(NODE_B))
  assert(paxe.keystore_set(NODE_A, 3, KEY))
  check_raises(function() paxe.protect(sockMain, {}) end, "config.peer", "missing peer raises")
  check_raises(function() paxe.protect(sockMain, { peer = NODE_A, channel = 42 }) end,
    "reserved", "reserved channel raises")

  check(paxe.protect(sockMain, { peer = NODE_A, channel = CHAN }) == true, "protect(sockMain)")
  local prot, ppeer, pchan = paxe.is_protected(sockMain)
  check(prot == true and ppeer == NODE_A and pchan == CHAN, "is_protected reports peer and channel")

  -- Disarm: an unencrypted datagram must now pass through RAW — the
  -- proof that protect genuinely controls behaviour (the deleted module
  -- printed "enabled" and changed nothing).
  check(paxe.unprotect(sockMain) == true and paxe.is_protected(sockMain) == false,
    "unprotect toggles protection off")
  local control = "control: socket currently unprotected"
  assert(udp.send(sockRaw, "127.0.0.1", PORT_MAIN, control))
  local cdata, _, _, cfrom, cchan = udp.recv(sockMain)
  check(cdata == control and cfrom == nil and cchan == nil,
    "unprotected recv passes datagrams through raw")
  check(paxe.protect(sockMain, { peer = NODE_A }) == true, "re-protect without channel")
  local _, _, dchan = paxe.is_protected(sockMain)
  check(dchan == 0, "default channel is 0")
  check(paxe.protect(sockMain, { peer = NODE_A, channel = CHAN }) == true, "protect with channel 137")

  -- ── legs 1+2: NEGATIVE FIRST, independence folded into the window ────
  s0 = paxe.stats()

  -- (1) THE crafted case: wire byte 8 (Lua index 9) is 0x04 — bit1=0,
  -- bit2=1, so it PASSES the flags constant-bit gate — but toId
  -- (bytes 3-4) is 9999, not this node. The EXPLICIT addressing check
  -- must drop it: rx_plaintext moves, rx_bad_flags must NOT.
  local crafted_flags_pass = string.char(0x00, 0x64, 0x27, 0x0F, 0x00, 0x89, 0x00, 0x0A, 0x04)
    .. string.rep("P", 20)
  -- (2) Plain ASCII text, no structure at all.
  local plain_ascii = "hello, this datagram was never encrypted"
  -- (3) The OTHER reject path: addressed TO this node (toId = 200) with
  -- byte 8 = 0x00 — it passes the addressing gate and reaches open(),
  -- where the flags gate rejects it: rx_bad_flags moves, rx_plaintext
  -- must NOT. This distinguishes the two reject paths.
  local forged_to_us_bad_flags = string.char(0x00, 0x64, 0x00, 0xC8, 0x00, 0x89, 0x00, 0x05, 0x00)
    .. string.rep("Q", 31)
  -- (4) Independence, protected side: raw bytes to the protected port.
  local independence_plain = "independence: plaintext to the protected port"
  -- Independence, unprotected side: raw bytes to the raw port.
  local independence_raw = "independence: raw datagram to the unprotected port"

  assert(udp.send(sockRaw, "127.0.0.1", PORT_MAIN, crafted_flags_pass))
  assert(udp.send(sockRaw, "127.0.0.1", PORT_MAIN, plain_ascii))
  assert(udp.send(sockRaw, "127.0.0.1", PORT_MAIN, forged_to_us_bad_flags))
  assert(udp.send(sockRaw, "127.0.0.1", PORT_MAIN, independence_plain))
  assert(udp.send(sockRaw, "127.0.0.1", PORT_RAW, independence_raw))

  -- The observer measures the negative window while the main coroutine
  -- is blocked in recv BELOW: that recv drains the four bad datagrams
  -- (counting each) and then waits — and no valid frame exists yet,
  -- because the sender only starts after this coroutine writes the ready
  -- file. Delta attribution is therefore exact per reject path.
  lunet.spawn(function()
    lunet.sleep(400)
    local s1 = paxe.stats()
    check(s1.rx_plaintext == s0.rx_plaintext + 3,
      "rx_plaintext +3: the unencrypted datagrams to the protected socket dropped by the EXPLICIT gate")
    -- The load-bearing pair: had the crafted flags-passing plaintext hit
    -- the flags gate, bad_flags would be +2 and plaintext +2; had the
    -- addressed forgery hit the addressing gate, the reverse.
    check(s1.rx_bad_flags == s0.rx_bad_flags + 1,
      "rx_bad_flags +1: only the addressed-to-us flags forgery took the codec path")
    check(s1.rx_ok == s0.rx_ok, "rx_ok unchanged: nothing reached Lua from the negative barrage")
    check(s1.rx_total == s0.rx_total + 4, "rx_total +4 (3 plaintext + 1 bad flags)")
    check(s1.rx_short == s0.rx_short and s1.rx_len_mismatch == s0.rx_len_mismatch
      and s1.rx_no_peer == s0.rx_no_peer and s1.rx_no_epoch == s0.rx_no_epoch
      and s1.rx_auth_fail == s0.rx_auth_fail,
      "no other reject counter moved (full attribution of the negative window)")
    local f = assert(io.open(e2e_dir .. "/ready", "w"))
    f:write("ready\n")
    f:close()
  end)

  -- Independence, unprotected side: the raw socket of THIS SAME PROCESS
  -- receives the unencrypted datagram untouched...
  local rdata, rhost, rport, rfrom, rchan = udp.recv(sockRaw)
  check(rdata == independence_raw and rhost == "127.0.0.1" and rport == PORT_RAW,
    "independence: unencrypted datagram passes raw on the unprotected socket")
  check(rfrom == nil and rchan == nil, "independence: raw recv carries no fromId/channel")

  -- ...while the protected socket delivers NOTHING for the barrage: this
  -- recv drains all four bad datagrams and blocks until node 100's first
  -- sealed frame arrives.
  local function expect_frame(want, what)
    local d, _, perr, f_id, c = udp.recv(sockMain)
    if d == nil then
      check(false, what .. " never arrived (recv: " .. tostring(perr)
        .. ") — unexpected drop or stalled receive, diagnose do not retry")
      return false
    end
    check(d == want, what .. " byte-exact (" .. #want .. " bytes over the wire)")
    check(f_id == NODE_A, what .. ": authenticated fromId 100 (genuinely different node id)")
    check(c == CHAN, what .. ": authenticated channel 137")
    return true
  end

  -- ── legs 3+4+5: POSITIVE, MODE BOUNDARY, MAX (frames arrive in order) ──
  local d0, h0, p0, f0, c0 = udp.recv(sockMain)
  if d0 == nil then
    check(false, "63-byte frame never arrived (recv: " .. tostring(p0)
      .. ") — unexpected drop or stalled receive, diagnose do not retry")
    return finalize(false)
  end
  check(d0 == P63, "positive: 63-byte payload byte-exact (standard mode on the wire)")
  check(f0 == NODE_A, "positive: authenticated fromId is 100")
  check(c0 == CHAN, "positive: authenticated channel is 137")
  check(h0 == "127.0.0.1" and p0 == PORT_A, "transport tuple is the sender's address")

  if not expect_frame(P64, "64-byte payload (standard)") then return finalize(false) end
  if not expect_frame(P65, "65-byte payload (standard)") then return finalize(false) end
  if not expect_frame(PLARGE, "8192-byte payload (standard, large frame)") then return finalize(false) end

  -- ── leg 5: MAX PAYLOAD at the documented maximum ─────────────────────
  -- The size invariant is UNCONDITIONAL: by construction the documented
  -- maxima are exactly the largest payloads whose frames fit one maximum
  -- UDP datagram. A drift in either constant breaks this.
  check(paxe.MAX_PAYLOAD_DEK + paxe.OVERHEAD_DEK == UDP_MAX,
    "MAX_PAYLOAD_DEK + OVERHEAD_DEK == 65507 = the UDP datagram limit (by construction)")
  check(paxe.MAX_PAYLOAD_STANDARD + paxe.OVERHEAD_STANDARD == UDP_MAX,
    "MAX_PAYLOAD_STANDARD + OVERHEAD_STANDARD == 65507 = the UDP datagram limit (by construction)")
  -- The wire traversal is platform-conditional, discriminated by the raw
  -- 65507-byte control the sender put on the UNPROTECTED socket ahead of
  -- a marker: if the platform drops max-size datagrams (macOS loopback
  -- refuses them with EMSGSIZE), the control never arrives and the
  -- marker does; if the platform carries them, the control arrives first
  -- and the sealed max frame MUST arrive too — its absence then is a
  -- GENUINE failure, not a platform property.
  local ctl = udp.recv(sockRaw)
  if ctl == nil then
    check(false, "max-payload probe: neither the raw control nor the marker arrived"
      .. " — unexpected drop or stalled receive, diagnose do not retry")
    return finalize(false)
  end
  if #ctl == RAW_CONTROL_LEN then
    local marker = udp.recv(sockRaw)
    check(marker == MAX_MARKER, "max-payload probe: marker follows the raw control")
    max_wire = true
    if not expect_frame(PMAX, "max payload 65470 bytes (frame 65507 = the UDP datagram limit)") then
      return finalize(false)
    end
  else
    check(ctl == MAX_MARKER,
      "max-payload probe: platform dropped the 65507-byte raw control (loopback cannot carry"
      .. " a maximum datagram — e.g. macOS EMSGSIZE); the sealed max frame's absence is a"
      .. " PLATFORM property, not a PAXE drop — wire leg skipped, invariant above stands")
  end

  local pos_frames = 4 + (max_wire and 1 or 0) -- 63/64/65/8192 (+ max)
  local s2 = paxe.stats()
  check(s2.rx_ok == s0.rx_ok + pos_frames,
    ("rx_ok +%d after the positive phase"):format(pos_frames))
  check(s2.rx_total == s0.rx_total + 4 + pos_frames,
    ("rx_total +%d after the positive phase"):format(4 + pos_frames))

  -- ── leg 6: CONCURRENCY — 4 sockets, 4 coroutines, 16 payloads ────────
  local conc = {}
  local conc_done = 0
  for i = 1, CONC_N do
    local sock = assert(udp.bind("127.0.0.1", CONC_PORT_BASE + i - 1))
    open_socks[sock] = true
    check(paxe.protect(sock, { peer = NODE_A, channel = 400 + i }) == true,
      ("concurrency: protect socket %d"):format(i))
    conc[i] = {}
    lunet.spawn(function()
      -- Let the burst queue in C before draining: the queued-datagram
      -- path is the one a single request/response cannot exercise.
      lunet.sleep(150)
      for k = 0, CONC_K - 1 do
        local d, _, perr, f_id, c = udp.recv(sock)
        if d == nil then
          check(false, ("concurrency socket %d seq %d: recv died (%s) — unexpected drop "
            .. "or stalled receive"):format(i, k, tostring(perr)))
          conc_done = conc_done + 1
          return
        end
        conc[i][#conc[i] + 1] = { data = d, from = f_id, chan = c }
      end
      close_sock(sock)
      check(paxe.is_protected(sock) == false,
        ("concurrency: close removed protection entry %d"):format(i))
      conc_done = conc_done + 1
    end)
  end
  do
    local f = assert(io.open(e2e_dir .. "/ready2", "w"))
    f:write("ready2\n")
    f:close()
  end
  while conc_done < CONC_N and not timed_out do
    lunet.sleep(50)
  end
  for i = 1, CONC_N do
    check(#conc[i] == CONC_K,
      ("concurrency socket %d received all %d of its datagrams"):format(i, CONC_K))
    for k = 0, CONC_K - 1 do
      local got = conc[i][k + 1]
      if got then
        check(got.data == conc_payload(i, k),
          ("concurrency socket %d seq %d: received its OWN payload (no crossed delivery)"):format(i, k))
        check(got.from == NODE_A and got.chan == CONC_CHAN_BASE + i,
          ("concurrency socket %d seq %d: authenticated fromId 100, channel %d")
            :format(i, k, CONC_CHAN_BASE + i))
      end
    end
  end

  finalize(true)
end

lunet.spawn(main)
