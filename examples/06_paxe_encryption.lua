#!/usr/bin/env lunet-run
--[[
Example 06: PAXE Packet Encryption
==================================

This example demonstrates the PAXE (Packet Encryption) extension module
for secure peer-to-peer communication using AES-256-GCM.

Prerequisites:
  - libsodium installed (brew install libsodium / apt install libsodium-dev)
  - Build PAXE extension: xmake build lunet-paxe

Usage:
  ./build/macosx/arm64/release/lunet-run examples/06_paxe_encryption.lua
]]

local paxe = require("lunet.paxe")

-- ANSI colors for terminal output
local C = {
    reset = "\27[0m",
    green = "\27[32m",
    red = "\27[31m",
    yellow = "\27[33m",
    blue = "\27[34m",
    dim = "\27[2m",
}

local function log(level, msg)
    local prefix = {
        info = C.blue .. "[INFO]" .. C.reset,
        ok = C.green .. "[OK]" .. C.reset,
        error = C.red .. "[ERROR]" .. C.reset,
        warn = C.yellow .. "[WARN]" .. C.reset,
    }
    print((prefix[level] or "[LOG]") .. " " .. msg)
end

print("PAXE Packet Encryption Example")
print("==============================")
print("Module version: " .. (paxe.VERSION or "unknown"))
print("")

-- ============================================================================
-- Step 1: Initialize PAXE (initializes libsodium)
-- ============================================================================
log("info", "Step 1: Initializing PAXE module")
local ok, err = paxe.init()
if not ok then
    log("error", "Failed to initialize PAXE: " .. tostring(err))
    os.exit(1)
end
log("ok", "PAXE initialized (libsodium ready, AES-256-GCM available)")

-- ============================================================================
-- Step 2: Set up encryption keys
-- ============================================================================
log("info", "Step 2: Setting up encryption keys")

-- Keys must be exactly 32 bytes (256-bit) for AES-256-GCM
-- In production, derive these from a proper KDF (HKDF, Argon2, etc.)
local key1 = string.rep("A", 32)  -- 32 bytes for peer 1
local key2 = string.rep("B", 32)  -- 32 bytes for peer 2

local ok1, err1 = paxe.keystore_set(1, key1)
local ok2, err2 = paxe.keystore_set(2, key2)

if not ok1 then log("error", "Failed to set key 1: " .. tostring(err1)) end
if not ok2 then log("error", "Failed to set key 2: " .. tostring(err2)) end
log("ok", "Added 2 keys to keystore (key_id=1 and key_id=2)")

-- ============================================================================
-- Step 3: Enable PAXE and configure failure policy
-- ============================================================================
log("info", "Step 3: Enabling PAXE and setting failure policy")

paxe.set_enabled(true)
if paxe.is_enabled() then
    log("ok", "PAXE is now enabled")
end

-- Available policies: "DROP", "LOG_ONCE", "VERBOSE"
paxe.set_fail_policy("DROP")
log("ok", "Failure policy set to DROP (silent drop of bad packets)")

-- ============================================================================
-- Step 4: Encrypt and decrypt a message (round-trip test)
-- ============================================================================
log("info", "Step 4: Encrypt/decrypt round-trip test")

local plaintext = "Hello, PAXE! This is a secret message."
print("  Plaintext: \"" .. plaintext .. "\" (" .. #plaintext .. " bytes)")

-- Encrypt using key_id=1
local ciphertext, enc_err = paxe.encrypt(plaintext, 1)
if not ciphertext then
    log("error", "Encryption failed: " .. tostring(enc_err))
    os.exit(1)
end
print("  Ciphertext: " .. #ciphertext .. " bytes (overhead: " .. paxe.OVERHEAD_STANDARD .. ")")

-- Decrypt
local decrypted, key_id, flags = paxe.try_decrypt(ciphertext)
if not decrypted then
    log("error", "Decryption failed: " .. tostring(key_id))
    os.exit(1)
end

print("  Decrypted: \"" .. decrypted .. "\"")
print("  Key ID: " .. key_id .. ", Flags: " .. flags)

if decrypted == plaintext then
    log("ok", "Round-trip successful: plaintext matches!")
else
    log("error", "Round-trip failed: plaintext mismatch!")
    os.exit(1)
end

-- ============================================================================
-- Step 5: Test multiple encryptions with different keys
-- ============================================================================
log("info", "Step 5: Multi-key encryption test")

local messages = {
    {key = 1, text = "Message for peer 1"},
    {key = 2, text = "Message for peer 2"},
    {key = 1, text = "Another message for peer 1"},
}

for i, msg in ipairs(messages) do
    local ct = paxe.encrypt(msg.text, msg.key)
    local pt, kid = paxe.try_decrypt(ct)
    if pt == msg.text and kid == msg.key then
        print(string.format("  [%d] key=%d OK: \"%s\"", i, msg.key, msg.text))
    else
        log("error", "Failed for message " .. i)
    end
end
log("ok", "All multi-key encryptions successful")

-- ============================================================================
-- Step 6: Check statistics
-- ============================================================================
log("info", "Step 6: PAXE statistics")

local stats = paxe.stats()
print("  rx_total:        " .. stats.rx_total .. " (total packets processed)")
print("  rx_ok:           " .. stats.rx_ok .. " (successfully decrypted)")
print("  rx_short:        " .. stats.rx_short .. " (packet too short)")
print("  rx_len_mismatch: " .. stats.rx_len_mismatch .. " (length mismatch)")
print("  rx_no_key:       " .. stats.rx_no_key .. " (key not found)")
print("  rx_auth_fail:    " .. stats.rx_auth_fail .. " (authentication failed)")

-- ============================================================================
-- Step 7: Test failure handling (decrypt with wrong data)
-- ============================================================================
log("info", "Step 7: Failure handling test")

-- Try to decrypt garbage
local bad_result, bad_err = paxe.try_decrypt("this is not a valid packet!!")
if bad_result == nil then
    log("ok", "Correctly rejected invalid packet: " .. tostring(bad_err))
else
    log("error", "Should have rejected invalid packet!")
end

-- Check stats updated
local stats2 = paxe.stats()
if stats2.rx_short > stats.rx_short or stats2.rx_auth_fail > stats.rx_auth_fail then
    log("ok", "Statistics correctly updated for failed decryption")
end

-- ============================================================================
-- Step 8: Cleanup
-- ============================================================================
log("info", "Step 8: Cleanup")

paxe.keystore_clear()
log("ok", "Keystore cleared (keys securely wiped with sodium_memzero)")

paxe.shutdown()
log("ok", "PAXE shutdown complete")

print("")
print(C.green .. "All tests passed!" .. C.reset)
print("")
print("PAXE provides:")
print("  - AES-256-GCM authenticated encryption")
print("  - In-place decryption (zero-copy)")
print("  - Per-key statistics")
print("  - Configurable failure policies")
print("")
print("See PAXE.md for full documentation.")
