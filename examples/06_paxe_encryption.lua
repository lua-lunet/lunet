#!/usr/bin/env lunet-run
--[[
Example 06: PAXE Datagram Encryption — API walkthrough
======================================================

PAXE is lunet's datagram encryption extension (integration reference:
docs/PAXE.md): one 32-byte shared key per link, addressed by (peer node
id, epoch); AES-256-GCM frames. seal() always produces a standard
one-recipient frame — the C ABI has no size-based mode selection; open()
additionally accepts reusable-DEK fanout frames sealed by a Rust host.
Per-socket UDP protection comes from paxe.protect().

Numbered steps:
   1. paxe.init()                         runtime init (AES-GCM requirement, core-dump suppression)
   2. paxe.set_local_id(node_id)          this node's identity (0-65535), configured ONCE
   3. paxe.keystore_set(peer, epoch, key) install a per-link key under an epoch
   4. paxe.seal(payload, to_id, channel)  encrypt for a peer
   5. one mode on the wire                63 and 64-byte payloads both seal standard
   6. rotation, send side                 installing a newer epoch switches senders AT ONCE
   7. paxe.open(frame)                    decrypt: payload + AUTHENTICATED fromId + channel
   8. an open() rejection                 the reason lives in the counters, never the return value
   9. epoch retirement                    a rolling key change — no flag day
  10. paxe.protect(sock)                  a datagram genuinely protected on a real UDP socket
  11. keystore_clear() + shutdown()       key erasure, final statistics, the counter invariant

One process holds ONE node identity (the Rust keystore is per-process),
so this script plays node 100 (the sending end) and then node 200 (the
receiving end) in sequence — the same discipline the two-process
end-to-end test (test/run_paxe_udp_e2e.sh) follows. Sealed frames are
just Lua strings (ciphertext); they survive the identity switch.

Prerequisites:
  - Build the PAXE extension:  xmake build-paxe
  - AES-256-GCM hardware path via libsodium. If this host lacks it,
    paxe.init() reports it and this example prints SKIP and exits 0 —
    PAXE refuses to substitute another cipher.

Usage:
  ./build/macosx/arm64/release/lunet-run examples/06_paxe_encryption.lua
  (set LUNET_PAXE_LIB to override the cdylib path)

Exit status: 0 on success (or a documented SKIP), non-zero on any failed
check or stalled receive — usable as a smoke test.
]]

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local chunk, load_err = loadfile(script_dir .. "/../ext/paxe/paxe.lua")
if not chunk then
  error("cannot load paxe.lua (build the extension with 'xmake build-paxe'): "
    .. tostring(load_err))
end
local paxe = chunk()
local lunet = require("lunet")
local udp = require("lunet.udp")

-- ANSI colors for terminal output
local C = {
  reset = "\27[0m",
  green = "\27[32m",
  red = "\27[31m",
  yellow = "\27[33m",
  blue = "\27[34m",
}

local failures = 0

local function log(level, msg)
  local prefix = {
    info = C.blue .. "[INFO]" .. C.reset,
    ok = C.green .. "[OK]" .. C.reset,
    error = C.red .. "[ERROR]" .. C.reset,
    warn = C.yellow .. "[WARN]" .. C.reset,
  }
  print((prefix[level] or "[LOG]") .. " " .. msg)
end

-- Non-fatal check: record and continue (the walkthrough prints every
-- step's verdict; the exit code summarises).
local function check(cond, msg)
  if cond then
    log("ok", msg)
  else
    failures = failures + 1
    log("error", msg)
  end
end

-- Fatal check: the walkthrough cannot meaningfully continue without it.
local function fatal(msg)
  log("error", msg)
  os.exit(1)
end

local NODE_A, NODE_B, CHAN = 100, 200, 137
-- Per-link 32-byte keys. In a real cluster keys are injected out of band
-- (e.g. provisioned over ssh) and never hard-coded; these are demo keys.
local KEY1 = string.rep("\x4B", 32) -- the A<->B link key, epoch 1
local KEY2 = string.rep("\x77", 32) -- the A<->B link key, epoch 2 (rotation)
local KEY_SELF = string.rep("\x53", 32) -- loopback self-link key (step 9 only)
-- open()'s ONE failure message for EVERY frame-level failure: the reason
-- is never surfaced to the caller (decryption-oracle avoidance).
local OPEN_REJECTED = "lunet.paxe: frame rejected"

local function wire_epoch(frame) return math.floor(frame:byte(9) / 8) end -- flags bits 3-7
local function dek_flag(frame) return frame:byte(9) % 2 end              -- flags bit 0

local main_done = false

local function main()
  print("PAXE Datagram Encryption Example")
  print("================================")
  print("Module version: " .. paxe.version())
  print(string.format("Constants: OVERHEAD_STANDARD=%d, OVERHEAD_DEK=%d, "
    .. "MAX_PAYLOAD_STANDARD=%d, MAX_PAYLOAD_DEK=%d",
    paxe.OVERHEAD_STANDARD, paxe.OVERHEAD_DEK,
    paxe.MAX_PAYLOAD_STANDARD, paxe.MAX_PAYLOAD_DEK))
  print("")

  -- Counters are process-global and cumulative for the process lifetime:
  -- measure DELTAS from a baseline, never absolute values.
  local s0 = paxe.stats()

  -- ==========================================================================
  log("info", "Step 1: paxe.init() — libsodium, AES-256-GCM, core-dump suppression")
  -- ==========================================================================
  local init_ok, init_err = paxe.init()
  if not init_ok then
    -- A host property (no AES-GCM hardware path in this libsodium build),
    -- not a failure of PAXE or of this script: skip cleanly.
    print("SKIP: " .. tostring(init_err))
    os.exit(0)
  end
  log("ok", "PAXE initialised (AES-256-GCM available; process core dumps disabled "
    .. "so crash dumps cannot carry key material — docs/PAXE.md \"Security Considerations\")")

  -- ==========================================================================
  log("info", "Step 2: paxe.set_local_id(" .. NODE_A .. ") — this node's identity, ONCE")
  -- ==========================================================================
  -- Node ids are 0-65535. One process = one node: the keystore is created
  -- with the identity, and a second call raises rather than silently
  -- re-creating the store (which would erase installed keys).
  if not paxe.set_local_id(NODE_A) then fatal("set_local_id failed") end
  local reconf_ok, reconf_err = pcall(paxe.set_local_id, 999)
  check(not reconf_ok and tostring(reconf_err):find("already configured", 1, true) ~= nil,
    "a second set_local_id() raises instead of silently wiping the keystore")

  -- ==========================================================================
  log("info", "Step 3: paxe.keystore_set(peer=" .. NODE_B .. ", epoch=1, key) — a per-link key")
  -- ==========================================================================
  -- Keys are 32-byte shared secrets, ONE PER LINK (per unordered node
  -- pair), addressed by (peer node id, epoch) — there is no key_id
  -- anywhere. peer: 0-65535, epoch: 0-31. Per-link granularity is what
  -- makes a forged fromId IMPOSSIBLE rather than merely unauthenticated:
  -- a third node does not hold the A<->B key (docs/PAXE.md "One key per link").
  if not paxe.keystore_set(NODE_B, 1, KEY1) then fatal("keystore_set failed") end
  log("ok", "installed the 100<->200 link key under epoch 1 (peer 0-65535, epoch 0-31, key 32 bytes)")

  -- ==========================================================================
  log("info", "Step 4: paxe.seal(payload, to_id=" .. NODE_B .. ", channel=" .. CHAN .. ") — encrypt for a peer")
  -- ==========================================================================
  -- The frame's fromId is the configured local id — never a parameter, so
  -- no caller can spoof a source. Channels 1-99 are reserved for system
  -- traffic; application channels start at 100 (channel 0 is permitted).
  local msg1 = "Node 100 seals this datagram for node 200 on channel 137."
  local frame1, seal_err = paxe.seal(msg1, NODE_B, CHAN)
  if not frame1 then fatal("seal failed: " .. tostring(seal_err)) end
  print(string.format("  payload: %d bytes -> frame: %d bytes (payload + %d standard overhead)",
    #msg1, #frame1, #frame1 - #msg1))
  check(#frame1 == #msg1 + paxe.OVERHEAD_STANDARD,
    "frame is payload + OVERHEAD_STANDARD (37): header 8 | flags 1 | nonce 12 | tag 16")

  -- ==========================================================================
  log("info", "Step 5: one mode on the wire — every seal is a standard frame")
  -- ==========================================================================
  -- There is NO size-based mode selection in this API: seal() always
  -- produces a standard one-recipient frame. (Reusable-DEK fanout sealing
  -- exists only in the Rust API; this host can still OPEN such a frame
  -- received from a Rust fanout host — open() would then report
  -- mode "dek".) Frame size is therefore always payload + 37.
  local s_tx = paxe.stats()
  local p63 = string.rep("s", 63)
  local p64 = string.rep("D", 64)
  local frame63 = assert(paxe.seal(p63, NODE_B, CHAN))
  local frame64 = assert(paxe.seal(p64, NODE_B, CHAN))
  print(string.format("  63-byte payload -> %d-byte frame (+%d)  |  64-byte payload -> %d-byte frame (+%d)",
    #frame63, #frame63 - 63, #frame64, #frame64 - 64))
  check(#frame63 == 63 + paxe.OVERHEAD_STANDARD and dek_flag(frame63) == 0,
    "63-byte payload sealed STANDARD (DEK flag clear, +37 bytes)")
  check(#frame64 == 64 + paxe.OVERHEAD_STANDARD and dek_flag(frame64) == 0,
    "64-byte payload sealed STANDARD too (DEK flag clear, +37 bytes)")
  local s_tx2 = paxe.stats()
  check(s_tx2.tx_standard == s_tx.tx_standard + 2 and s_tx2.tx_dek == s_tx.tx_dek,
    "tx counters: both payloads count tx_standard; tx_dek does not move")
  print("  One extra payload byte grew the frame by exactly one byte: same mode, same overhead.")

  -- ==========================================================================
  log("info", "Step 6: rotation, send side — installing a newer epoch switches senders AT ONCE")
  -- ==========================================================================
  -- seal() takes no epoch parameter: the send epoch is always the NEWEST
  -- epoch installed for the peer. This is what makes rotation a procedure
  -- rather than an event (docs/PAXE.md "Rotation").
  if not paxe.keystore_set(NODE_B, 2, KEY2) then fatal("keystore_set epoch 2 failed") end
  local msg2 = "epoch 2 traffic: same peer, newer key"
  local frame2 = assert(paxe.seal(msg2, NODE_B, CHAN))
  check(wire_epoch(frame1) == 1 and wire_epoch(frame2) == 2,
    "frame1 carries epoch 1, frame2 carries epoch 2 (flags bits 3-7, inside the authenticated span)")

  -- ==========================================================================
  log("info", "Step 7: paxe.open(frame) — payload + AUTHENTICATED fromId + channel")
  -- ==========================================================================
  -- One process holds one node identity, so to play the receiving end we
  -- become node 200: shutdown() zeroes every key and forgets the identity
  -- (the sealed FRAMES are ciphertext strings in Lua and survive), then
  -- node 200's keystore is provisioned with the same link keys.
  paxe.shutdown()
  if not paxe.set_local_id(NODE_B) then fatal("set_local_id(200) failed") end
  assert(paxe.keystore_set(NODE_A, 1, KEY1))
  assert(paxe.keystore_set(NODE_A, 2, KEY2))

  local d1, from1, chan1, mode1 = paxe.open(frame1)
  if not d1 then fatal("open(frame1) rejected a valid frame") end
  check(d1 == msg1, "payload recovered byte-exact")
  check(from1 == NODE_A and chan1 == CHAN and mode1 == "standard",
    "recovered fromId=100, channel=137, mode=standard")

  -- TEACHING POINT: fromId is AUTHENTICATED (it sits inside the AES-GCM
  -- AAD), so it can be trusted for decisions. Under per-link keys, only a
  -- holder of the 100<->200 key could have sealed a frame claiming
  -- fromId=100 addressed to 200 — a third node cannot forge it.
  local ADMIN_NODES = { [100] = true, [101] = true }
  local decision = ADMIN_NODES[from1] and "ACCEPT (admin node)" or "REFUSE"
  print("  ACL decision on the authenticated fromId: node " .. from1 .. " -> " .. decision)
  check(decision == "ACCEPT (admin node)",
    "sender identity is trustworthy enough to authorize against")

  -- The two size probes open too, both reporting standard mode.
  local d63, _, _, m63 = paxe.open(frame63)
  local d64, _, _, m64 = paxe.open(frame64)
  check(d63 == p63 and m63 == "standard", "63-byte frame opened: byte-exact, mode reported \"standard\"")
  check(d64 == p64 and m64 == "standard", "64-byte frame opened: byte-exact, mode reported \"standard\"")

  -- ==========================================================================
  log("info", "Step 8: a rejection — the reason is ONLY in the counters, never the return value")
  -- ==========================================================================
  -- A forged frame claiming to be from node 9999 (no link provisioned):
  -- header(from=9999, to=200, channel=137, length=0), a flags byte that
  -- passes the constant-bit filter (0x04: standard, epoch 0), nonce, tag.
  local forged = string.char(0x27, 0x0F, 0x00, 0xC8, 0x00, 0x89, 0x00, 0x00, 0x04)
    .. string.rep("\0", 28)
  local s_rej = paxe.stats()
  local drop1, err1 = paxe.open(forged)
  check(drop1 == nil and err1 == OPEN_REJECTED,
    "forgery rejected with the ONE opaque message: \"" .. tostring(err1) .. "\"")
  local s_rej2 = paxe.stats()
  check(s_rej2.rx_no_peer == s_rej.rx_no_peer + 1
    and s_rej2.rx_total == s_rej.rx_total + 1 and s_rej2.rx_ok == s_rej.rx_ok,
    "the reason never reaches the caller — rx_no_peer +1 is the only place it survives")
  -- A receiver that explains WHY a forgery failed is a decryption oracle
  -- (docs/PAXE.md "Failure handling"): EVERY frame-level failure — too short,
  -- flags, length, unknown peer, unknown epoch, authentication — returns
  -- this same message. The counters are the only diagnostic channel.
  local b30 = frame64:byte(30)
  local corrupted = frame64:sub(1, 29) .. string.char(255 - b30) .. frame64:sub(31)
  local drop2, err2 = paxe.open(corrupted)
  check(drop2 == nil and err2 == OPEN_REJECTED,
    "a corrupted frame gets the SAME opaque message (indistinguishable by design)")
  local s_rej3 = paxe.stats()
  check(s_rej3.rx_auth_fail == s_rej2.rx_auth_fail + 1,
    "rx_auth_fail +1 (a corrupted ciphertext byte fails the AES-GCM tag check)")

  -- ==========================================================================
  log("info", "Step 9: epoch retirement — a rolling key change, NOT a flag day")
  -- ==========================================================================
  -- TEACHING POINT: the 5-bit epoch exists so a key change need not be a
  -- flag day. Both epochs are installed on both ends; senders switched to
  -- the new epoch the moment it was installed (step 6); receivers open
  -- old- and new-epoch traffic throughout; the old epoch is retired once
  -- no sender uses it.
  check(paxe.open(frame2) == msg2, "epoch 2 frame opens under the new key")
  check(paxe.open(frame1) == msg1, "epoch 1 frame STILL opens: old and new epochs coexist")
  local s_rot = paxe.stats()
  check(paxe.keystore_retire(NODE_A, 1) == true, "keystore_retire(peer 100, epoch 1): a key was retired")
  local drop3, err3 = paxe.open(frame1)
  check(drop3 == nil and err3 == OPEN_REJECTED, "after retirement, the epoch-1 frame is rejected")
  local s_rot2 = paxe.stats()
  check(s_rot2.rx_no_epoch == s_rot.rx_no_epoch + 1,
    "rx_no_epoch +1: the peer is known but the epoch is gone — a rotation problem, not topology")
  check(paxe.keystore_retire(NODE_A, 1) == false,
    "retiring an absent slot returns false (informational, not an error)")
  check(paxe.open(frame2) == msg2, "epoch 2 traffic is unaffected by the retirement")

  -- ==========================================================================
  log("info", "Step 10: paxe.protect(sock) — a datagram genuinely protected on a real UDP socket")
  -- ==========================================================================
  -- Protection is PER-SOCKET and this is the only enable mechanism: there
  -- is deliberately no process-global set_enabled — an earlier module's
  -- global switch printed "enabled" while protecting nothing, and one
  -- flag cannot express a process serving both an encrypted cluster port
  -- and an unencrypted local port. Protection here is demonstrated by
  -- BEHAVIOUR: a plaintext datagram is dropped, a sealed one delivered.
  --
  -- One process = one node id, so the loopback demo installs a self-link
  -- key (peer == local id) and sends a datagram to itself. The genuine
  -- two-node wire proof is the e2e test: test/run_paxe_udp_e2e.sh.
  assert(paxe.keystore_set(NODE_B, 0, KEY_SELF))
  local PORT_RX, PORT_TX, PORT_RAW = 20771, 20772, 20773
  local sockRx = assert(udp.bind("127.0.0.1", PORT_RX))
  local sockTx = assert(udp.bind("127.0.0.1", PORT_TX))
  local sockRaw = assert(udp.bind("127.0.0.1", PORT_RAW)) -- stays unprotected
  check(paxe.protect(sockRx, { peer = NODE_B, channel = 150 }) == true, "protect(sockRx, peer 200, channel 150)")
  check(paxe.protect(sockTx, { peer = NODE_B, channel = 150 }) == true, "protect(sockTx, peer 200, channel 150)")
  local prot, ppeer, pchan = paxe.is_protected(sockRx)
  check(prot == true and ppeer == NODE_B and pchan == 150, "is_protected reports peer 200, channel 150")

  local s_udp = paxe.stats()
  -- (a) An unencrypted datagram to the protected socket: the explicit
  -- plaintext gate drops it (rx_plaintext) and NOTHING is delivered.
  assert(udp.send(sockRaw, "127.0.0.1", PORT_RX, "this datagram was never encrypted"))
  -- (b) A protected send: udp.send seals before transmission; what goes
  -- on the wire is a 41+37=78-byte frame, not the 41-byte payload.
  local wire_msg = "protected datagram over a real UDP socket" -- 41 bytes
  assert(udp.send(sockTx, "127.0.0.1", PORT_RX, wire_msg))
  print(string.format("  on the wire: %d payload bytes left the socket as a %d-byte sealed frame",
    #wire_msg, #wire_msg + paxe.OVERHEAD_STANDARD))
  -- recv drains the dropped plaintext first, then delivers the opened frame.
  local data, host, port, from_id, chan = udp.recv(sockRx)
  if not data then fatal("protected recv returned no data: " .. tostring(host)) end
  check(data == wire_msg, "protected recv delivered the payload byte-exact")
  check(from_id == NODE_B and chan == 150,
    "protected recv surfaced the authenticated fromId=200 and channel=150")
  check(host == "127.0.0.1" and port == PORT_TX, "transport tuple is the sender's address")
  local s_udp2 = paxe.stats()
  check(s_udp2.rx_plaintext == s_udp.rx_plaintext + 1,
    "the unencrypted datagram was dropped: rx_plaintext +1, nothing reached Lua")
  check(s_udp2.rx_ok == s_udp.rx_ok + 1 and s_udp2.tx_total == s_udp.tx_total + 1,
    "the sealed datagram was delivered: rx_ok +1, tx_total +1")
  check(paxe.unprotect(sockTx) == true and paxe.is_protected(sockTx) == false,
    "unprotect disarms the socket (close also removes the protection entry)")
  udp.close(sockRx)
  udp.close(sockTx)
  udp.close(sockRaw)

  -- ==========================================================================
  log("info", "Step 11: keystore_clear() + shutdown() — erasure and final statistics")
  -- ==========================================================================
  assert(paxe.keystore_clear())
  local noseal, noseal_err = paxe.seal("x", NODE_A, CHAN)
  check(noseal == nil and type(noseal_err) == "string"
    and noseal_err:find("no key installed", 1, true) ~= nil,
    "after keystore_clear() no seal is possible: " .. tostring(noseal_err))
  paxe.shutdown()
  log("ok", "every key zeroed and freed, identity forgotten (an atexit hook does "
    .. "the same even when a script never calls shutdown())")

  -- Final statistics: DELTAS from the baseline (counters never reset).
  local sE = paxe.stats()
  local function d(k) return sE[k] - s0[k] end
  print("")
  print("  Run statistics (deltas from baseline):")
  print(string.format("    tx_total=%d  tx_standard=%d  tx_dek=%d  tx_oversize=%d",
    d("tx_total"), d("tx_standard"), d("tx_dek"), d("tx_oversize")))
  print(string.format("    rx_total=%d  rx_ok=%d", d("rx_total"), d("rx_ok")))
  print(string.format("    rejects: plaintext=%d short=%d bad_flags=%d len_mismatch=%d "
    .. "no_peer=%d no_epoch=%d auth_fail=%d",
    d("rx_plaintext"), d("rx_short"), d("rx_bad_flags"), d("rx_len_mismatch"),
    d("rx_no_peer"), d("rx_no_epoch"), d("rx_auth_fail")))
  -- The counter invariant: every frame presented to a configured receiver
  -- lands in exactly one bucket.
  local rejects = d("rx_plaintext") + d("rx_short") + d("rx_bad_flags") + d("rx_len_mismatch")
    + d("rx_no_peer") + d("rx_no_epoch") + d("rx_auth_fail")
  check(d("rx_total") == d("rx_ok") + rejects,
    "INVARIANT holds: rx_total == rx_ok + sum(all reject reasons)")

  print("")
  if failures == 0 then
    print(C.green .. "All checks passed!" .. C.reset)
  else
    print(C.red .. failures .. " check(s) FAILED" .. C.reset)
  end
  print("")
  print("PAXE provides:")
  print("  - AES-256-GCM authenticated encryption, one 32-byte key per link")
  print("  - keys addressed by (peer node id, epoch) — rotation without flag days")
  print("  - authenticated fromId: trustworthy sender identity for decisions")
  print("  - one frame mode on the wire: standard, at every payload size")
  print("  - per-socket UDP protection (paxe.protect) — no global enable switch")
  print("  - drop semantics with counters as the only diagnostic channel")
  print("")
  print("See docs/PAXE.md for the integration reference (the normative wire")
  print("contract is paxe-core's PAXE.md, linked from there).")

  main_done = true
  os.exit(failures == 0 and 0 or 1)
end

-- lunet's udp API is coroutine-only: the whole walkthrough runs inside
-- lunet.spawn. A watchdog bounds the run: a TIMEOUT means a datagram was
-- dropped that should not have been, or a receive stalled — a failure.
lunet.spawn(function()
  local ok, err = pcall(main)
  if not ok then
    log("error", "walkthrough aborted: " .. tostring(err))
    os.exit(1)
  end
end)

lunet.spawn(function()
  lunet.sleep(15000)
  if not main_done then
    log("error", "TIMEOUT after 15000 ms: a receive stalled or an unexpected "
      .. "datagram drop occurred — diagnose, do not retry")
    os.exit(2)
  end
end)
