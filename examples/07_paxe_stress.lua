#!/usr/bin/env lunet-run
--[[
Example 07: PAXE Stress Test
============================

A STRESS test, not a benchmark: it exists to make the wrong thing happen
loudly, not to make a number look good. Under configurable load it:

  - varies payload sizes across the 64-byte mode boundary
    (63, 64, 65, 128, 1024 bytes -> standard and DEK frame geometries)
  - injects deliberate failures: unknown peer, retired epoch, corrupted
    frame — exercising the rejection paths and their counters, the paths
    least likely to have been run
  - asserts BYTE-EXACT correctness on EVERY iteration (payload, fromId,
    channel, mode, frame size, and the one opaque rejection message)
  - reconciles the final counters against the operations performed,
    including the item08 invariant:
        rx_total == rx_ok + sum(all reject reasons)

Any throughput figure printed is measured on the machine it runs on and
labelled as such; it is informational, not a benchmark target.

One process holds ONE node identity (the Rust keystore is per-process),
so the stress traffic uses a self-link (peer == local id): seal() looks
the key up by toId, open() by fromId, and both land on the same
(peer, epoch) slot. The crypto and every rejection path are identical to
a two-node deployment; only the addressing is what a loopback makes it.
"Concurrency" means interleaved lunet coroutines on the one VM thread —
lunet's execution model — not OS threads.

Prerequisites:
  - Build the PAXE extension:  xmake build-paxe
  - AES-256-GCM hardware path via libsodium; without it this script
    prints SKIP and exits 0 (PAXE refuses a software fallback).

Environment variables:
  ITERATIONS   total operations across all workers (default: 1000)
  CONCURRENCY  worker coroutines (default: 4)
  FAIL_EVERY   every Nth op is an injected failure (default: 10)
  WATCHDOG_MS  hard bound on the whole run (default: 120000)

Usage:
  ITERATIONS=10000 CONCURRENCY=8 \
    ./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua

Exit status: 0 only when every iteration asserted correct and every
counter reconciles; 1 on any failure; 2 on watchdog timeout.
]]

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local chunk, load_err = loadfile(script_dir .. "/../ext/paxe/paxe.lua")
if not chunk then
  error("cannot load paxe.lua (build the extension with 'xmake build-paxe'): "
    .. tostring(load_err))
end
local paxe = chunk()
local lunet = require("lunet")

local ITERATIONS = tonumber(os.getenv("ITERATIONS")) or 1000
local CONCURRENCY = tonumber(os.getenv("CONCURRENCY")) or 4
local FAIL_EVERY = tonumber(os.getenv("FAIL_EVERY")) or 10
local WATCHDOG_MS = tonumber(os.getenv("WATCHDOG_MS")) or 120000

if ITERATIONS < 1 or CONCURRENCY < 1 or FAIL_EVERY < 1 or WATCHDOG_MS < 1000 then
  print("[FAIL] invalid configuration: ITERATIONS>=1, CONCURRENCY>=1, FAIL_EVERY>=1, "
    .. "WATCHDOG_MS>=1000 required")
  os.exit(1)
end

print(string.format(
  "[PAXE STRESS] Config: iterations=%d, concurrency=%d, fail_every=%d, watchdog_ms=%d",
  ITERATIONS, CONCURRENCY, FAIL_EVERY, WATCHDOG_MS
))

-- ============================================================================
-- Setup: identity, keys, and the two standing rejection fixtures.
-- ============================================================================
local init_ok, init_err = paxe.init()
if not init_ok then
  print("SKIP: " .. tostring(init_err))
  os.exit(0)
end

local SELF = 100
local KEY1 = string.rep("\x4B", 32) -- self-link key, epoch 1 (retired during setup)
local KEY2 = string.rep("\x77", 32) -- self-link key, epoch 2 (the live send epoch)
local OPAQUE = "lunet.paxe: frame rejected" -- open()'s ONE failure message

assert(paxe.set_local_id(SELF))
assert(paxe.keystore_set(SELF, 1, KEY1))
-- The retired-epoch fixture: a frame sealed under epoch 1 BEFORE the key
-- rotation below. Opening it after the retirement must fail (rx_no_epoch).
local frame_old = assert(paxe.seal("sealed under epoch 1, since retired", SELF, 137))
assert(math.floor(frame_old:byte(9) / 8) == 1, "fixture must carry wire epoch 1")
assert(paxe.keystore_set(SELF, 2, KEY2))
assert(paxe.keystore_retire(SELF, 1) == true)

-- The unknown-peer fixture: a forged frame from node 9999 (no link
-- provisioned): header(from=9999, to=100, channel=137, length=0), a flags
-- byte that passes the constant-bit filter, nonce, tag. -> rx_no_peer.
local FRAME_NO_PEER = string.char(0x27, 0x0F, 0x00, 0x64, 0x00, 0x89, 0x00, 0x00, 0x04)
  .. string.rep("\0", 28)

-- Payload sizes cross the 64-byte mode boundary: 63 standard; 64, 65,
-- 128, 1024 DEK. Deterministic round-robin: reproducible op mix.
local SIZES = { 63, 64, 65, 128, 1024 }
local KINDS = { "no_peer", "no_epoch", "auth_fail" }

local function mkpayload(i, size)
  local p = "PAXE07|i=" .. i .. "|s=" .. size .. "|"
  return p .. string.rep(string.char(65 + (i % 26)), size - #p)
end

-- Baseline AFTER setup: the reconciliation window covers only the stress
-- ops below (counters are process-global and never reset; measure deltas).
local s0 = paxe.stats()

-- ============================================================================
-- The ops. Every op performs exactly ONE open(), so the expected rx_total
-- over the window is exactly ITERATIONS. Failures of an assertion record
-- an error; they never silently pass.
-- ============================================================================
local function run_op(i, tally, bad)
  if i % FAIL_EVERY == 0 then
    -- Deliberate failure injection (round-robin over the three kinds).
    local kind = KINDS[(math.floor(i / FAIL_EVERY) - 1) % #KINDS + 1]
    if kind == "no_peer" then
      local d, e = paxe.open(FRAME_NO_PEER)
      tally.opens = tally.opens + 1
      if d ~= nil or e ~= OPAQUE then
        bad(i, "no_peer", "expected the opaque rejection, got "
          .. tostring(d) .. ", " .. tostring(e))
      else
        tally.no_peer = tally.no_peer + 1
      end
    elseif kind == "no_epoch" then
      local d, e = paxe.open(frame_old)
      tally.opens = tally.opens + 1
      if d ~= nil or e ~= OPAQUE then
        bad(i, "no_epoch", "expected the opaque rejection, got "
          .. tostring(d) .. ", " .. tostring(e))
      else
        tally.no_epoch = tally.no_epoch + 1
      end
    else -- auth_fail: seal a valid frame, corrupt one ciphertext byte, open it
      local payload = mkpayload(i, 63) -- standard frame: byte 30 sits in the ciphertext
      local frame, serr = paxe.seal(payload, SELF, 137)
      if not frame then
        bad(i, "auth_fail", "seal failed: " .. tostring(serr))
        return
      end
      tally.seals = tally.seals + 1
      tally.tx_standard = tally.tx_standard + 1
      local corrupted = frame:sub(1, 29) .. string.char(255 - frame:byte(30)) .. frame:sub(31)
      local d, e = paxe.open(corrupted)
      tally.opens = tally.opens + 1
      if d ~= nil or e ~= OPAQUE then
        bad(i, "auth_fail", "expected the opaque rejection, got "
          .. tostring(d) .. ", " .. tostring(e))
      else
        tally.auth_fail = tally.auth_fail + 1
      end
    end
    return
  end

  -- Round trip: seal, then open, asserting EVERYTHING on every iteration.
  local size = SIZES[(i % #SIZES) + 1]
  local chan = 100 + (i % 8) -- application channels, all distinct modulo 8
  local payload = mkpayload(i, size)
  local want_overhead = size < 64 and paxe.OVERHEAD_STANDARD or paxe.OVERHEAD_DEK
  local want_mode = size < 64 and "standard" or "dek"
  local frame, serr = paxe.seal(payload, SELF, chan)
  if not frame then
    bad(i, "roundtrip", "seal failed: " .. tostring(serr))
    return
  end
  tally.seals = tally.seals + 1
  if size < 64 then tally.tx_standard = tally.tx_standard + 1
  else tally.tx_dek = tally.tx_dek + 1 end
  if #frame ~= size + want_overhead then
    bad(i, "roundtrip", string.format("frame size %d, expected %d (payload %d + overhead %d)",
      #frame, size + want_overhead, size, want_overhead))
  end
  local d, from, c, mode = paxe.open(frame)
  tally.opens = tally.opens + 1
  if d == nil then
    bad(i, "roundtrip", "open rejected a valid frame: " .. tostring(from))
    return
  end
  if d ~= payload then
    bad(i, "roundtrip", "payload mismatch (not byte-exact)")
    return
  end
  if from ~= SELF then
    bad(i, "roundtrip", "fromId " .. tostring(from) .. ", expected " .. SELF)
    return
  end
  if c ~= chan then
    bad(i, "roundtrip", "channel " .. tostring(c) .. ", expected " .. chan)
    return
  end
  if mode ~= want_mode then
    bad(i, "roundtrip", "mode " .. tostring(mode) .. ", expected " .. want_mode)
    return
  end
  tally.rx_ok = tally.rx_ok + 1
end

-- ============================================================================
-- Workers: ITERATIONS strided across CONCURRENCY coroutines. Counts are
-- tallied per worker and merged afterwards — coroutines yield only at
-- lunet.sleep(0), so no locking is needed (single VM thread).
-- ============================================================================
local errors = 0
local error_samples = {}
local workers_done = 0
local totals = {
  opens = 0, rx_ok = 0, seals = 0, tx_standard = 0, tx_dek = 0,
  no_peer = 0, no_epoch = 0, auth_fail = 0,
}

local t0
local function main()
  t0 = os.clock()
  for w = 1, CONCURRENCY do
    lunet.spawn(function()
      local ok, werr = pcall(function()
        local tally = {
          opens = 0, rx_ok = 0, seals = 0, tx_standard = 0, tx_dek = 0,
          no_peer = 0, no_epoch = 0, auth_fail = 0,
        }
        local function bad(i, kind, msg)
          errors = errors + 1
          if #error_samples < 10 then
            error_samples[#error_samples + 1] =
              string.format("  iter %d [%s]: %s", i, kind, msg)
          end
        end
        local n = 0
        local i = w
        while i <= ITERATIONS do
          run_op(i, tally, bad)
          n = n + 1
          if CONCURRENCY > 1 and n % 64 == 0 then lunet.sleep(0) end -- interleave workers
          i = i + CONCURRENCY
        end
        for k, v in pairs(tally) do totals[k] = totals[k] + v end
      end)
      if not ok then
        errors = errors + 1
        error_samples[#error_samples + 1] = "  worker " .. w .. " died: " .. tostring(werr)
      end
      workers_done = workers_done + 1
    end)
  end

  -- Watchdog: a stalled run is a FAILURE (exit 2), never a silent hang.
  lunet.spawn(function()
    lunet.sleep(WATCHDOG_MS)
    if workers_done < CONCURRENCY then
      print(string.format("[FAIL] TIMEOUT after %d ms: %d/%d workers finished",
        WATCHDOG_MS, workers_done, CONCURRENCY))
      os.exit(2)
    end
  end)

  while workers_done < CONCURRENCY do lunet.sleep(20) end
  local elapsed_ms = (os.clock() - t0) * 1000

  -- ==========================================================================
  -- Counter reconciliation: counters are the only diagnostic channel for
  -- drops, so they must account for EVERY operation, exactly.
  -- ==========================================================================
  local s1 = paxe.stats()
  local function d(k) return s1[k] - s0[k] end
  local recon_failures = 0
  local function recon(cond, msg)
    if cond then
      print("   OK: " .. msg)
    else
      recon_failures = recon_failures + 1
      print("FAIL: " .. msg)
    end
  end

  print("")
  print("[PAXE STRESS] Counter reconciliation (deltas over the run):")
  local rejects = d("rx_plaintext") + d("rx_short") + d("rx_bad_flags") + d("rx_len_mismatch")
    + d("rx_no_peer") + d("rx_no_epoch") + d("rx_dek_len_mismatch") + d("rx_auth_fail")
  recon(d("rx_total") == d("rx_ok") + rejects,
    "invariant: rx_total == rx_ok + sum(all reject reasons)")
  recon(d("rx_total") == totals.opens,
    string.format("rx_total == opens performed (%d == %d)", d("rx_total"), totals.opens))
  recon(d("rx_ok") == totals.rx_ok,
    string.format("rx_ok == successful round trips (%d)", totals.rx_ok))
  recon(d("rx_no_peer") == totals.no_peer,
    string.format("rx_no_peer == injected unknown-peer frames (%d)", totals.no_peer))
  recon(d("rx_no_epoch") == totals.no_epoch,
    string.format("rx_no_epoch == injected retired-epoch frames (%d)", totals.no_epoch))
  recon(d("rx_auth_fail") == totals.auth_fail,
    string.format("rx_auth_fail == injected corrupted frames (%d)", totals.auth_fail))
  recon(d("rx_plaintext") == 0 and d("rx_short") == 0 and d("rx_bad_flags") == 0
    and d("rx_len_mismatch") == 0 and d("rx_dek_len_mismatch") == 0,
    "no other reject counter moved (the injections hit exactly the intended paths)")
  recon(d("tx_total") == totals.seals,
    string.format("tx_total == seals performed (%d)", totals.seals))
  recon(d("tx_standard") == totals.tx_standard and d("tx_dek") == totals.tx_dek
    and d("tx_standard") + d("tx_dek") == d("tx_total"),
    string.format("tx_standard (%d) + tx_dek (%d) == tx_total", totals.tx_standard, totals.tx_dek))
  recon(d("tx_oversize") == 0, "tx_oversize == 0 (no oversized offers in this test)")

  -- ==========================================================================
  -- Report.
  -- ==========================================================================
  local round_trips = totals.rx_ok
  local injected = totals.no_peer + totals.no_epoch + totals.auth_fail
  print("")
  print("[PAXE STRESS] Results:")
  print(string.format("  operations total:    %d (%d round trips + %d injected failures)",
    totals.opens, round_trips, injected))
  print("  correctness:         byte-exact payload/fromId/channel/mode asserted on EVERY op")
  print(string.format("  injected failures:   no_peer=%d, no_epoch=%d, auth_fail=%d "
    .. "(all returned the one opaque message)", totals.no_peer, totals.no_epoch, totals.auth_fail))
  print(string.format("  errors:              %d", errors))
  for _, s in ipairs(error_samples) do print(s) end
  if errors > #error_samples then
    print(string.format("  ... and %d more", errors - #error_samples))
  end
  if elapsed_ms > 0 then
    local ms_fmt = elapsed_ms < 10 and "%.2f" or "%.0f"
    print(string.format(
      "  measured throughput: %d ops in " .. ms_fmt .. " ms, ~%.0f ops/sec "
      .. "(measured on this machine, this run — informational, not a benchmark target)",
      totals.opens, elapsed_ms, totals.opens / (elapsed_ms / 1000)))
  end

  -- Cleanup.
  paxe.keystore_clear()
  paxe.shutdown()

  print("")
  if errors == 0 and recon_failures == 0 then
    print("[OK] Stress test passed: every operation correct, every counter reconciled")
    os.exit(0)
  end
  print(string.format("[FAIL] Stress test failed: %d op error(s), %d reconciliation failure(s)",
    errors, recon_failures))
  os.exit(1)
end

lunet.spawn(function()
  local ok, err = pcall(main)
  if not ok then
    print("[FAIL] stress test aborted: " .. tostring(err))
    os.exit(1)
  end
end)
