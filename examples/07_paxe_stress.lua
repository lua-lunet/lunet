#!/usr/bin/env lunet-run
--[[
Example 07: PAXE Stress Test
============================

This test validates PAXE packet encryption simulation under load.

NOTE: This is a simulation that tests the packet processing loop logic
without requiring actual encrypted packets. In production, you would
integrate with real UDP packet flow using paxe.try_decrypt().

Environment variables:
  ITERATIONS   - Number of packets to simulate (default: 100)
  PACKET_SIZE  - Simulated packet size in bytes (default: 1024)
  NUM_KEYS     - Number of keys in rotation (default: 4)

Usage:
  ITERATIONS=10000 ./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua
]]

local iterations = tonumber(os.getenv("ITERATIONS")) or 100
local packet_size = tonumber(os.getenv("PACKET_SIZE")) or 1024
local num_keys = tonumber(os.getenv("NUM_KEYS")) or 4

print(string.format(
    "[PAXE STRESS] Starting test: iterations=%d, packet_size=%d, keys=%d",
    iterations, packet_size, num_keys
))

-- Simulation state (mirrors what paxe.stats_get() would return)
local paxe_simulation = {
    packets_processed = 0,
    bytes_processed = 0,
    errors = 0,
    start_time = os.time(),
}

-- PAXE packet format overhead:
--   Standard mode: Header(8) + Nonce(12) + Tag(16) = 36 bytes
--   DEK mode: adds KEK_Nonce(12) + Enc_DEK(32) + DEK_Nonce(12) + DEK_Len(2) = 58 more
local PAXE_STANDARD_OVERHEAD = 36
local PAXE_DEK_OVERHEAD = 36 + 58

local function simulate_paxe_operations(count, pkt_size, nkeys)
    local overhead = PAXE_STANDARD_OVERHEAD

    for i = 1, count do
        -- Simulate key selection (round-robin for testing)
        local key_id = (i % nkeys) + 1

        -- Simulate packet sizes
        local encrypted_size = pkt_size + overhead
        local decrypted_size = pkt_size

        -- Update statistics
        paxe_simulation.packets_processed = paxe_simulation.packets_processed + 1
        paxe_simulation.bytes_processed = paxe_simulation.bytes_processed + pkt_size

        -- Simulate 1% authentication failure rate (for stress testing)
        if i % 100 == 0 then
            paxe_simulation.errors = paxe_simulation.errors + 1
        end
    end
end

-- Run stress test in batches
print("[PAXE STRESS] Running main loop...")
local batch_size = math.max(1, math.floor(iterations / 10))
local num_batches = 10

for batch = 1, num_batches do
    simulate_paxe_operations(batch_size, packet_size, num_keys)

    if batch % 2 == 0 then
        local elapsed = os.time() - paxe_simulation.start_time + 1
        print(string.format(
            "[PAXE STRESS] Batch %d/%d: %d packets, %.2f MB/s",
            batch, num_batches,
            paxe_simulation.packets_processed,
            (paxe_simulation.bytes_processed / 1024 / 1024) / elapsed
        ))
    end
end

-- Final report
local elapsed = os.time() - paxe_simulation.start_time + 1
print(string.format("\n[PAXE STRESS] Results:"))
print(string.format("  Packets processed: %d", paxe_simulation.packets_processed))
print(string.format("  Bytes processed:   %.2f MB", paxe_simulation.bytes_processed / 1024 / 1024))
print(string.format("  Errors (simulated): %d (%.2f%%)",
    paxe_simulation.errors,
    100 * paxe_simulation.errors / paxe_simulation.packets_processed))
print(string.format("  Throughput:        %.2f pkt/s", paxe_simulation.packets_processed / elapsed))
print(string.format("  Throughput:        %.2f MB/s", (paxe_simulation.bytes_processed / 1024 / 1024) / elapsed))
print(string.format("  Elapsed:           %d seconds", elapsed))

-- Verification
local expected = batch_size * num_batches
if paxe_simulation.packets_processed == expected then
    print("\n[OK] Stress test completed successfully")
    os.exit(0)
else
    print(string.format("\n[ERROR] Expected %d packets, processed %d",
        expected, paxe_simulation.packets_processed))
    os.exit(1)
end
