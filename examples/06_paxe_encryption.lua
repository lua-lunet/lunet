#!/usr/bin/env lunet-run
--[[
Example 06: PAXE Packet Encryption (API Preview)
================================================

This example demonstrates the planned PAXE (Packet Encryption) API.

NOTE: Lua bindings are not yet implemented. This example shows the
intended API design for when FFI bindings are added. Currently,
PAXE is C-only and can be called via LuaJIT FFI.

PAXE is an extension module that:
- Requires libsodium for cryptographic operations
- Uses AES-256-GCM for authenticated encryption
- Performs in-place decryption to minimize memory copying
- Provides per-peer key management and statistics

Prerequisites:
  - libsodium installed (brew install libsodium / apt install libsodium-dev)
  - Build PAXE extension: xmake build lunet-paxe

For C API usage, see PAXE.md and include/paxe.h
]]

-- ANSI colors for terminal output
local colors = {
    reset = "\27[0m",
    green = "\27[32m",
    red = "\27[31m",
    yellow = "\27[33m",
    blue = "\27[34m",
    dim = "\27[2m",
}

local function log(level, msg)
    local prefix = {
        info = colors.blue .. "[INFO]" .. colors.reset,
        ok = colors.green .. "[OK]" .. colors.reset,
        error = colors.red .. "[ERROR]" .. colors.reset,
        warn = colors.yellow .. "[WARN]" .. colors.reset,
        note = colors.dim .. "[NOTE]" .. colors.reset,
    }
    print((prefix[level] or "[LOG]") .. " " .. msg)
end

log("note", "This is an API preview - Lua bindings are pending implementation")
print("")

-- ============================================================================
-- Simulated PAXE module (mirrors planned C API)
-- ============================================================================
local paxe = {
    _initialized = false,
    _enabled = false,
    _keys = {},
    _policy = "DROP",
    _stats = {
        rx_total = 0,
        rx_ok = 0,
        rx_short = 0,
        rx_len_mismatch = 0,
        rx_no_key = 0,
        rx_auth_fail = 0,
    }
}

function paxe.init()
    if paxe._initialized then
        return true
    end
    -- In real implementation: calls sodium_init()
    paxe._initialized = true
    paxe._enabled = true
    return true
end

function paxe.shutdown()
    paxe._initialized = false
    paxe._enabled = false
    paxe._keys = {}
end

function paxe.is_enabled()
    return paxe._enabled
end

function paxe.set_enabled(enabled)
    paxe._enabled = enabled
end

function paxe.keystore_set(key_id, key)
    if #key ~= 32 then
        return false, "key must be 32 bytes"
    end
    paxe._keys[key_id] = key
    return true
end

function paxe.keystore_clear()
    -- In real implementation: calls sodium_memzero() on each key
    paxe._keys = {}
    return true
end

function paxe.set_fail_policy(policy)
    if policy ~= "DROP" and policy ~= "LOG_ONCE" and policy ~= "VERBOSE" then
        return false, "invalid policy"
    end
    paxe._policy = policy
    return true
end

function paxe.stats_get()
    return paxe._stats
end

-- ============================================================================
-- Step 1: Initialize PAXE
-- ============================================================================
log("info", "Step 1: Initializing PAXE module")
local ok, err = paxe.init()
if not ok then
    log("error", "Failed to initialize PAXE: " .. tostring(err))
    os.exit(1)
end
log("ok", "PAXE initialized successfully (libsodium ready)")

-- ============================================================================
-- Step 2: Set up encryption keys for peers
-- ============================================================================
log("info", "Step 2: Setting up encryption keys")

-- Keys must be exactly 32 bytes (256-bit) for AES-256-GCM
-- In production, derive these from a KDF (e.g., HKDF, Argon2)
local key_peer1 = string.rep("\x01", 32)  -- Test key for peer 1
local key_peer2 = string.rep("\x02", 32)  -- Test key for peer 2

-- Register keys with unique IDs (used in packet headers)
paxe.keystore_set(1, key_peer1)
paxe.keystore_set(2, key_peer2)
log("ok", "Added 2 keys to keystore (key_id=1 and key_id=2)")

-- ============================================================================
-- Step 3: Configure failure policies
-- ============================================================================
log("info", "Step 3: Configuring failure policies")

-- Available policies:
--   "DROP"     - Silently drop failed packets (default, safest)
--   "LOG_ONCE" - Log first failure per peer (detect attacks without noise)
--   "VERBOSE"  - Log all failures (debugging only)
paxe.set_fail_policy("DROP")
log("ok", "Set failure policy to DROP (malformed/unauth packets dropped)")

-- ============================================================================
-- Step 4: Enable/Disable PAXE dynamically
-- ============================================================================
log("info", "Step 4: Testing enable/disable")

paxe.set_enabled(true)
if paxe.is_enabled() then
    log("ok", "PAXE is now enabled")
else
    log("error", "Failed to enable PAXE")
end

paxe.set_enabled(false)
if not paxe.is_enabled() then
    log("ok", "PAXE is now disabled")
else
    log("error", "Failed to disable PAXE")
end

-- Re-enable for statistics demo
paxe.set_enabled(true)

-- ============================================================================
-- Step 5: Check statistics
-- ============================================================================
log("info", "Step 5: Reading PAXE statistics")

local stats = paxe.stats_get()
if stats then
    print("  rx_total:        " .. (stats.rx_total or 0) .. " (packets received)")
    print("  rx_ok:           " .. (stats.rx_ok or 0) .. " (successfully decrypted)")
    print("  rx_short:        " .. (stats.rx_short or 0) .. " (packet too short)")
    print("  rx_len_mismatch: " .. (stats.rx_len_mismatch or 0) .. " (length mismatch)")
    print("  rx_no_key:       " .. (stats.rx_no_key or 0) .. " (key not found)")
    print("  rx_auth_fail:    " .. (stats.rx_auth_fail or 0) .. " (authentication failed)")
else
    log("warn", "Statistics not available")
end

-- ============================================================================
-- Step 6: Integration notes
-- ============================================================================
log("info", "Step 6: Integration with UDP")
print([[
  In a real application, PAXE would be integrated into the UDP receive path:

    -- C API (current implementation)
    ssize_t plaintext_len = paxe_try_decrypt(buf, len, &key_id, &flags);
    if (plaintext_len < 0) {
        // Packet dropped (policy already applied)
        return;
    }

    -- Future Lua API (once FFI bindings added)
    local plaintext_len, key_id, flags = paxe.try_decrypt(buf, len)
    if plaintext_len < 0 then
        return  -- Packet dropped
    end
]])

-- ============================================================================
-- Step 7: Cleanup
-- ============================================================================
log("info", "Step 7: Cleanup")

-- Securely wipe all keys from memory (uses sodium_memzero in C)
paxe.keystore_clear()
log("ok", "Keystore cleared (keys securely wiped)")

-- Shutdown PAXE module
paxe.shutdown()
log("ok", "PAXE shutdown complete")

print("")
print(colors.green .. "All steps completed successfully!" .. colors.reset)
print("")
print("This example demonstrates the planned PAXE Lua API.")
print("For current usage, call the C API via LuaJIT FFI.")
print("See PAXE.md for full documentation and packet format details.")
