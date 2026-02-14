#!/usr/bin/env lunet-run
--[[
Example 07: PAXE Stress Test
============================

This stress test validates PAXE packet encryption under load:
- Multiple encryption/decryption operations
- Multi-key rotation
- Statistics verification
- Performance measurement

Prerequisites:
  - libsodium installed (brew install libsodium / apt install libsodium-dev)
  - Build PAXE extension: xmake build lunet-paxe

Environment variables:
  ITERATIONS   - Number of encrypt/decrypt cycles (default: 1000)
  PACKET_SIZE  - Plaintext size in bytes (default: 1024)
  NUM_KEYS     - Number of keys in rotation (default: 4)

Usage:
  ITERATIONS=10000 ./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua
]]

local paxe = require("lunet.paxe")

local iterations = tonumber(os.getenv("ITERATIONS")) or 1000
local packet_size = tonumber(os.getenv("PACKET_SIZE")) or 1024
local num_keys = tonumber(os.getenv("NUM_KEYS")) or 4

print(string.format(
    "[PAXE STRESS] Config: iterations=%d, packet_size=%d, num_keys=%d",
    iterations, packet_size, num_keys
))

-- Initialize PAXE
local ok, err = paxe.init()
if not ok then
    print("[ERROR] Failed to initialize PAXE: " .. tostring(err))
    os.exit(1)
end
print("[PAXE STRESS] PAXE initialized")

-- Set up keys
for i = 1, num_keys do
    -- Generate deterministic test keys (NOT for production!)
    local key = string.char(i):rep(32)
    local ok, err = paxe.keystore_set(i, key)
    if not ok then
        print("[ERROR] Failed to set key " .. i .. ": " .. tostring(err))
        os.exit(1)
    end
end
print(string.format("[PAXE STRESS] Added %d keys to keystore", num_keys))

paxe.set_enabled(true)
paxe.set_fail_policy("DROP")

-- Generate test plaintext
local plaintext = string.rep("X", packet_size)

-- Timing
local start_time = os.clock()
local errors = 0
local bytes_processed = 0

print("[PAXE STRESS] Running encryption/decryption cycles...")

-- Main stress loop
for i = 1, iterations do
    -- Round-robin key selection
    local key_id = ((i - 1) % num_keys) + 1

    -- Encrypt
    local ciphertext, enc_err = paxe.encrypt(plaintext, key_id)
    if not ciphertext then
        errors = errors + 1
        if errors <= 5 then
            print("[ERROR] Encryption failed at iteration " .. i .. ": " .. tostring(enc_err))
        end
    else
        -- Decrypt
        local decrypted, dec_key_id, flags = paxe.try_decrypt(ciphertext)
        if not decrypted then
            errors = errors + 1
            if errors <= 5 then
                print("[ERROR] Decryption failed at iteration " .. i)
            end
        elseif decrypted ~= plaintext then
            errors = errors + 1
            if errors <= 5 then
                print("[ERROR] Plaintext mismatch at iteration " .. i)
            end
        elseif dec_key_id ~= key_id then
            errors = errors + 1
            if errors <= 5 then
                print("[ERROR] Key ID mismatch at iteration " .. i)
            end
        else
            bytes_processed = bytes_processed + packet_size
        end
    end

    -- Progress report
    if i % (iterations / 10) == 0 then
        local pct = math.floor(i / iterations * 100)
        local elapsed = os.clock() - start_time
        local rate = bytes_processed / (1024 * 1024) / elapsed
        print(string.format(
            "[PAXE STRESS] %3d%% complete: %d ops, %.2f MB/s",
            pct, i, rate
        ))
    end
end

local elapsed = os.clock() - start_time
local successful = iterations - errors

-- Final statistics
print("")
print("[PAXE STRESS] Results:")
print(string.format("  Total iterations:  %d", iterations))
print(string.format("  Successful:        %d (%.2f%%)", successful, successful / iterations * 100))
print(string.format("  Errors:            %d", errors))
print(string.format("  Bytes processed:   %.2f MB", bytes_processed / 1024 / 1024))
print(string.format("  Elapsed time:      %.3f seconds", elapsed))
print(string.format("  Throughput:        %.2f ops/sec", iterations / elapsed))
print(string.format("  Throughput:        %.2f MB/sec", bytes_processed / 1024 / 1024 / elapsed))

-- PAXE internal statistics
print("")
print("[PAXE STRESS] PAXE Statistics:")
local stats = paxe.stats()
print(string.format("  rx_total:        %d", stats.rx_total))
print(string.format("  rx_ok:           %d", stats.rx_ok))
print(string.format("  rx_auth_fail:    %d", stats.rx_auth_fail))
print(string.format("  rx_no_key:       %d", stats.rx_no_key))

-- Cleanup
paxe.keystore_clear()
paxe.shutdown()

-- Verdict
print("")
if errors == 0 then
    print("[OK] Stress test completed successfully - all " .. iterations .. " operations passed")
    os.exit(0)
else
    print("[FAIL] Stress test completed with " .. errors .. " errors")
    os.exit(1)
end
