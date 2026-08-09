---@meta

---@class paxe
---PAXE (Packet Encryption) — AES-256-GCM authenticated encryption for lunet.
---Requires libsodium. Keys must be exactly 32 bytes.
local paxe = {}

---Initialize PAXE and libsodium. Call once before any other PAXE function.
---@return string|nil ok "ok" on success
---@return string|nil error Error message if failed
---@usage
---```lua
---local paxe = require("lunet.paxe")
---local ok, err = paxe.init()
---if not ok then error(err) end
---```
function paxe.init() end

---Shutdown PAXE and clean up libsodium resources.
function paxe.shutdown() end

---Enable or disable encryption.
---@param enabled boolean
function paxe.set_enabled(enabled) end

---Check whether encryption is enabled.
---@return boolean enabled
function paxe.is_enabled() end

---Store a symmetric key. Keys must be exactly 32 bytes (256-bit).
---@param key_id integer Key identifier (uint32)
---@param key_string string Exactly 32 bytes
---@return string|nil ok "ok" on success
---@return string|nil error Error message if failed
function paxe.keystore_set(key_id, key_string) end

---Wipe all keys securely from memory using sodium_memzero.
function paxe.keystore_clear() end

---Set the failure policy when a packet cannot be decrypted.
---@param policy string "DROP", "LOG_ONCE", or "VERBOSE"
function paxe.set_fail_policy(policy) end

---Encrypt plaintext with the given key.
---@param plaintext string Data to encrypt
---@param key_id integer Key identifier to use for encryption
---@return string|nil ciphertext Encrypted packet, or nil on error
---@return string|nil error Error message if failed
function paxe.encrypt(plaintext, key_id) end

---Attempt to decrypt a ciphertext in-place.
---@param ciphertext string The encrypted packet
---@return string|nil plaintext Decrypted data, or nil on failure
---@return integer|nil key_id Key identifier that was used for encryption
---@return integer|nil flags Header flags byte from the packet
---@return string|nil error Error message if decryption failed
function paxe.try_decrypt(ciphertext) end

---Retrieve encryption/decryption statistics.
---@return table stats { rx_total, rx_ok, rx_short, rx_len_mismatch,
--- rx_no_key, rx_auth_fail, rx_reserved_nonzero } (all uint64)
function paxe.stats() end

---Standard-mode overhead in bytes (header + nonce + tag).
---@type integer
paxe.OVERHEAD_STANDARD = nil

---DEK-mode overhead in bytes (standard overhead + encrypted DEK + DEK nonce + length).
---@type integer
paxe.OVERHEAD_DEK = nil

---Module version string.
---@type string
paxe.VERSION = nil

return paxe
