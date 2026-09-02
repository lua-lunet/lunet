---@meta

---lunet.sodium — a minimal libsodium primitive surface.
---
---Three primitives exposed from the PAXE cdylib (which already statically
---links libsodium): one-shot SHA-256, one-shot HMAC-SHA-256 (the JWT HS256
---primitive), and `randombytes`. Loaded through the LuaJIT FFI from the
---dylib handle — never `RTLD_DEFAULT` — so a user-owned libsodium in the
---same process cannot capture the lookup. Requires the PAXE cdylib
---(`xmake build-paxe`; shipped in the binary archives).
---
---Security boundary: stateless hashing crosses no secrets; the HMAC key
---material does cross the FFI unguarded (documented boundary — guarded key
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

---One-shot HMAC-SHA-256 — the JWT HS256 primitive. `key` must be exactly
---32 bytes (a wrong length raises). The key crosses the FFI as ordinary
---Lua string data — unguarded, unlike PAXE keystore material.
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

return sodium
