-- item14 PERMANENT end-to-end test, SENDER side (PAXE node 100). Driven
-- by test/run_paxe_udp_e2e.sh, which starts it only after the receiver
-- (node 200) has signalled readiness — two processes because the Rust
-- keystore holds ONE node identity per process. The receiver generates
-- its own negative barrage; this side sends ONLY sealed frames and
-- asserts the transmit counters per leg (the tx side of the wire proof:
-- tx_standard vs tx_dek is what ties each payload to its on-the-wire
-- frame geometry).
--
-- Legs: an oversized payload fails the send with a clear error (nothing
-- is transmitted, tx_oversize moves); the positive sequence
-- 63/64/65/8192/max bytes (standard/DEK/DEK/DEK/DEK — the max frame is
-- 65507 bytes, exactly the UDP datagram limit); a raw 65507-byte control
-- plus marker on an UNPROTECTED socket so the receiver can tell a
-- platform that cannot carry a maximum datagram (macOS loopback:
-- EMSGSIZE) apart from a genuine PAXE drop; then the concurrency burst —
-- 4 coroutines, each on its own protected socket, 16 distinguishable
-- payloads interleaved with sleep(0).
--
-- TIMEOUT INTERPRETATION: the sender blocks only on the receiver's
-- ready/ready2 marker files, each with a hard deadline. A TIMEOUT here
-- means the receiver is down or stalled — diagnose from the receiver's
-- log in the run's .tmp/logs/<timestamp>/ directory; do not retry.
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
local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. msg)
  else
    print("   OK: " .. msg)
  end
end

local KEY = string.rep("\x42", 32)
local NODE_A, NODE_B, CHAN = 100, 200, 137
local PORT_MAIN, PORT_A, PORT_RAW = 20411, 20412, 20413
local CONC_N, CONC_K, CONC_PORT_BASE, CONC_CHAN_BASE = 4, 4, 20420, 300
local WAIT_MS = 10000

-- Payload generators. KEEP IN SYNC with test/paxe_udp_receiver.lua —
-- the wire assertions compare byte-for-byte against these exact strings.
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
  return string.rep(table.concat(t), 261):sub(1, paxe.MAX_PAYLOAD_DEK)
end)()
-- Raw control for the receiver's max-payload platform probe: exactly one
-- maximum UDP datagram (65535 - 20 - 8), sent UNENCRYPTED ahead of a
-- small marker. NOTE: lunet's udp.send reports only uv_udp_send()'s
-- synchronous result — an async kernel refusal (macOS EMSGSIZE on
-- loopback) surfaces only in the send callback, which udp.c ignores.
-- The RECEIVER's control recv is therefore the verdict, not this send.
local UDP_MAX = 65535 - 20 - 8
local RAW_CONTROL = string.rep("\xA5", UDP_MAX)
local MAX_MARKER = "PAXE14-MAXRAW-DONE"
local function conc_payload(i, k)
  local p = ("PAXE14-C|i=%d|k=%d|"):format(i, k)
  return p .. string.rep(string.char(96 + i * 4 + k), 14)
end

local function wait_file(path, deadline_ms, what)
  local waited = 0
  while waited < deadline_ms do
    local f = io.open(path, "r")
    if f then
      f:close()
      return true
    end
    lunet.sleep(100)
    waited = waited + 100
  end
  check(false, "TIMEOUT waiting for " .. what
    .. ": the receiver is down or stalled — diagnose, do not retry")
  return false
end

local function finish()
  local df = assert(io.open(e2e_dir .. "/done", "w"))
  df:write(failures > 0 and "FAIL\n" or "PASS\n")
  df:close()
  print(failures > 0 and ("=== sender: " .. failures .. " FAILURES ===")
    or ("=== sender: all " .. checks .. " checks passed ==="))
  os.exit(failures > 0 and 1 or 0)
end

local function main()
  print("=== paxe udp e2e (item14): sender (node 100) ===")

  local init_ok, init_err = paxe.init()
  if not init_ok then
    print("SKIP: AES-256-GCM unavailable on this host: " .. tostring(init_err))
    os.exit(0)
  end
  assert(paxe.set_local_id(NODE_A))
  assert(paxe.keystore_set(NODE_B, 3, KEY))

  if not wait_file(e2e_dir .. "/ready", WAIT_MS, "ready") then return finish() end

  local sockA, aerr = udp.bind("127.0.0.1", PORT_A)
  assert(sockA, aerr)
  check(paxe.protect(sockA, { peer = NODE_B, channel = CHAN }) == true, "protect(sockA)")

  -- The frame at the documented maximum is exactly one maximum UDP
  -- datagram BY MEASUREMENT of a real seal (before the counter windows).
  local frame_max = assert(paxe.seal(PMAX, NODE_B, CHAN))
  check(#frame_max == UDP_MAX,
    "seal(documented max) produces a 65507-byte frame = exactly the UDP datagram limit")

  -- Oversized payload: the send FAILS with a clear error naming the
  -- selected mode's maximum; nothing is sealed or transmitted.
  local s0 = paxe.stats()
  local ok, err = udp.send(sockA, "127.0.0.1", PORT_MAIN, string.rep("x", paxe.MAX_PAYLOAD_DEK + 1))
  check(ok == nil and type(err) == "string" and err:find("65424", 1, true) ~= nil,
    "oversized send fails with a clear error naming 65424")
  local s1 = paxe.stats()
  check(s1.tx_oversize == s0.tx_oversize + 1, "tx_oversize +1")
  check(s1.tx_total == s0.tx_total, "an oversized offer seals nothing")

  -- Positive sequence: 63 (standard), 64/65/8192/max (DEK). The max
  -- frame is 65424 + 83 = 65507 bytes = exactly the UDP datagram limit:
  -- a sizing error in the documented maximum fails the seal HERE, and a
  -- synchronous transport refusal fails the send HERE.
  check(udp.send(sockA, "127.0.0.1", PORT_MAIN, P63) == true, "send 63-byte payload")
  check(udp.send(sockA, "127.0.0.1", PORT_MAIN, P64) == true, "send 64-byte payload")
  check(udp.send(sockA, "127.0.0.1", PORT_MAIN, P65) == true, "send 65-byte payload")
  check(udp.send(sockA, "127.0.0.1", PORT_MAIN, PLARGE) == true, "send 8192-byte payload")
  check(udp.send(sockA, "127.0.0.1", PORT_MAIN, PMAX) == true,
    "send max payload 65424 bytes (frame 65507 = the UDP datagram limit)")
  local s2 = paxe.stats()
  check(s2.tx_total == s1.tx_total + 5, "tx_total +5 for the positive sequence")
  check(s2.tx_standard == s1.tx_standard + 1,
    "63-byte payload sealed standard (automatic mode selection)")
  check(s2.tx_dek == s1.tx_dek + 4, "64/65/8192/max payloads sealed DEK (both geometries on the wire)")

  -- The platform probe: a raw maximum-size datagram plus a marker to the
  -- receiver's UNPROTECTED socket (see RAW_CONTROL above). A synchronous
  -- refusal of the control send just means the platform is incapable —
  -- the receiver takes the platform-skip branch on the marker alone.
  local sockCtl, cerr = udp.bind("127.0.0.1", 0)
  assert(sockCtl, cerr)
  udp.send(sockCtl, "127.0.0.1", PORT_RAW, RAW_CONTROL)
  check(udp.send(sockCtl, "127.0.0.1", PORT_RAW, MAX_MARKER) == true,
    "send max-probe marker to the unprotected socket")
  -- Let the event loop drain the send queue BEFORE closing: libuv queues
  -- a send it cannot complete synchronously (the doomed 65507-byte
  -- control on macOS) and uv_close CANCELS queued sends — closing here
  -- without the pause would silently drop the marker behind the control.
  lunet.sleep(50)
  assert(udp.close(sockCtl))

  -- ── Concurrency: 4 coroutines, own socket each, interleaved sends ────
  if not wait_file(e2e_dir .. "/ready2", WAIT_MS, "ready2") then
    udp.close(sockA)
    return finish()
  end
  local senders_done = 0
  for i = 1, CONC_N do
    lunet.spawn(function()
      local sock, berr = udp.bind("127.0.0.1", 0)
      if not sock then
        check(false, ("concurrency sender %d bind: %s"):format(i, tostring(berr)))
        senders_done = senders_done + 1
        return
      end
      local pok, perr = pcall(paxe.protect, sock, { peer = NODE_B, channel = CONC_CHAN_BASE + i })
      if not pok then
        check(false, ("concurrency sender %d protect: %s"):format(i, tostring(perr)))
        udp.close(sock)
        senders_done = senders_done + 1
        return
      end
      for k = 0, CONC_K - 1 do
        local sok, serr = udp.send(sock, "127.0.0.1", CONC_PORT_BASE + i - 1, conc_payload(i, k))
        check(sok == true, ("concurrency sender %d seq %d sent: %s"):format(i, k, tostring(serr)))
        lunet.sleep(0) -- yield so the four sender coroutines genuinely interleave
      end
      udp.close(sock)
      senders_done = senders_done + 1
    end)
  end
  local waited = 0
  while senders_done < CONC_N and waited < WAIT_MS do
    lunet.sleep(50)
    waited = waited + 50
  end
  check(senders_done == CONC_N, "all 4 concurrency sender coroutines completed")
  local s3 = paxe.stats()
  check(s3.tx_total == s2.tx_total + CONC_N * CONC_K, "concurrency: tx_total +16")
  check(s3.tx_standard == s2.tx_standard + CONC_N * CONC_K,
    "concurrency payloads all sealed standard (<64 bytes)")

  assert(udp.close(sockA))
  paxe.shutdown()
  finish()
end

lunet.spawn(main)
