---@meta

---lunet.sodium  -  a minimal libsodium primitive surface.
---
---Three primitives exposed from the PAXE cdylib (which already statically
---links libsodium): one-shot SHA-256, one-shot HMAC-SHA-256 (the JWT HS256
---primitive), and `randombytes`. Loaded through the LuaJIT FFI from the
---dylib handle  -  never `RTLD_DEFAULT`  -  so a user-owned libsodium in the
---same process cannot capture the lookup. Requires the PAXE cdylib
---(`xmake build-paxe`; shipped in the binary archives).
---
---Security boundary: stateless hashing crosses no secrets; the HMAC key
---material does cross the FFI unguarded (documented boundary  -  guarded key
---memory remains `lunet.paxe`'s job). See `docs/SODIUM.md`.
local sodium = {}

---Digest/tag size in bytes of `sha256` and `hmac_sha256` outputs (32).
---@type integer
sodium.BYTES = nil

---One-shot SHA-256.
---
---Malformed arguments raise; an operational failure (libsodium init)
---returns `nil, message`.
---@param data string Data to hash
---@return string digest 32 raw bytes
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local d = sodium.sha256("abc")
---```
function sodium.sha256(data) end

---One-shot HMAC-SHA-256  -  the JWT HS256 primitive. `key` must be exactly
---32 bytes (a wrong length raises). The key crosses the FFI as ordinary
---Lua string data  -  unguarded, unlike PAXE keystore material.
---@param data string Data to authenticate
---@param key string Exactly 32 bytes
---@return string tag 32 raw bytes
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local sig = sodium.hmac_sha256(payload, key32)
---```
function sodium.hmac_sha256(data, key) end

---Draw `n` unpredictable bytes from the same CSPRNG PAXE uses (never mix
---two RNGs in one process). `n` is a non-negative integer; 0 returns the
---empty string.
---@param n integer Number of bytes to draw
---@return string bytes n raw bytes
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local nonce = sodium.random(12)
---```
function sodium.random(n) end

---Encode `data` to base64 with the linked library's own transform.
---`variant` selects the alphabet and padding policy from the
---`sodium.BASE64_VARIANT_*` constants. Malformed arguments (non-string
---data, unknown variant) raise; an operational failure returns
---`nil, message`.
---@param data string Bytes to encode
---@param variant integer One of the BASE64_VARIANT constants
---@return string b64 Encoded text
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local b64 = sodium.base64_encode(data, sodium.BASE64_VARIANT_URLSAFE_NO_PADDING)
---```
function sodium.base64_encode(data, variant) end

---Decode base64 back to bytes with the linked library's own transform.
---The URL-safe variants accept either padded or unpadded input, per the
---library. Malformed input or an unknown variant raises with the
---library's diagnostic. The result is binary: its length, not a NUL,
---says where it ends.
---@param data string Encoded text
---@param variant integer One of the BASE64_VARIANT constants
---@return string bytes Decoded bytes
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local bin = sodium.base64_decode(token, sodium.BASE64_VARIANT_URLSAFE_NO_PADDING)
---```
function sodium.base64_decode(data, variant) end

---Base64 variant selection for `base64_encode` / `base64_decode`, with
---values fixed by libsodium itself.
---@type integer
sodium.BASE64_VARIANT_ORIGINAL = nil

---@type integer
sodium.BASE64_VARIANT_ORIGINAL_NO_PADDING = nil

---@type integer
sodium.BASE64_VARIANT_URLSAFE = nil

---@type integer
sodium.BASE64_VARIANT_URLSAFE_NO_PADDING = nil

---Argon2id password hashing (interactive limits by default).
---@param password string
---@param opts table|nil
---@return string|nil hash
---@return string|nil error
function sodium.pwhash_str(password, opts) end

---Verify an Argon2id password hash.
---@param password string
---@param hash string
---@return boolean|nil ok
---@return string|nil error
function sodium.pwhash_str_verify(password, hash) end

return sodium
