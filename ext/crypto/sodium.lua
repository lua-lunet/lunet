-- lunet.sodium: a MINIMAL libsodium primitive surface, loaded from the
-- standalone crypto cdylib (liblunet_crypto) through the LuaJIT FFI (the
-- jsonic loader model). SHA-256, HMAC-SHA-256 (the JWT HS256 primitive),
-- randombytes, base64 and Argon2id password hashing  -  see
-- docs/SODIUM.md.
--
-- WHY THIS EXISTS: without it every consumer ships its own libsodium FFI
-- boilerplate (or loads a SECOND libsodium  -  homebrew, distro  -  with
-- dlsym(RTLD_DEFAULT) ambiguity). This module binds through the dylib
-- HANDLE returned by ffi.load below, never through ffi.C / RTLD_DEFAULT,
-- so a user-owned libsodium in the same process can never capture the
-- lookup.
--
-- ABI PROMISE (deliberately narrow): the lunet_sodium_* symbols below.
-- No wholesale export of the libsodium namespace  -  the vendored
-- sodium version is not a public ABI promise, and a full export would be
-- a symbol-collision hazard with user-loaded sodiums. No streaming or
-- incremental variants; no keyring or guarded key memory.
--
-- ERROR CONVENTION: malformed arguments RAISE a Lua error (they are bugs
-- in the calling script); operational failures (libsodium could not be
-- initialised) return nil, message.
-- TYPE CHECKS RUN HERE: by the time a value crosses the FFI its Lua type
-- is invisible to Rust, so this module validates every argument before
-- the call.
--
-- SECURITY BOUNDARY (docs/SODIUM.md states it too): stateless hashing
-- crosses no secrets; the HMAC key is ordinary Lua string data and DOES
-- cross the FFI unguarded  -  a documented boundary.

local ffi = require("ffi")

ffi.cdef[[
  int lunet_sodium_sha256(const uint8_t* input, size_t input_len, uint8_t* out);
  int lunet_sodium_hmac_sha256(const uint8_t* input, size_t input_len,
                               const uint8_t* key, size_t key_len, uint8_t* out);
  int lunet_sodium_randombytes(uint8_t* out, size_t out_len);
  int lunet_sodium_pwhash_str(const uint8_t* passwd, size_t passwd_len,
                              unsigned long long opslimit, size_t memlimit,
                              uint8_t* out, size_t out_cap);
  int lunet_sodium_pwhash_str_verify(const uint8_t* hash, size_t hash_len,
                                     const uint8_t* passwd, size_t passwd_len);
  int lunet_sodium_base64_encode(const uint8_t* input, size_t input_len,
                                 int variant, uint8_t* out, size_t out_cap);
  int lunet_sodium_base64_decode(const uint8_t* input, size_t input_len,
                                 int variant, uint8_t* out, size_t out_cap,
                                 size_t* written);
  const uint8_t* lunet_crypto_last_error(size_t* len);
]]

-- Return codes, mirroring src/lib.rs (the crypto cdylib's ABI).
local RC_OK = 0     -- success
local RC_OK_ABSENT = 1 -- informational: pwhash verification did not match
local RC_ERR = -1   -- operational failure -> nil, last_error()
local RC_INVAL = -2 -- malformed argument -> raise last_error()

-- Digest/tag size of both hash primitives (crypto_hash_sha256_BYTES and
-- crypto_auth_hmacsha256_BYTES are both 32 in every libsodium release).
local BYTES = 32

-- Find the crypto cdylib: environment override first, then the
-- loader's own directory and its cargo output tree. The returned handle
-- is what every symbol below binds through  -  never ffi.C, never a
-- bare name.
local function find_lib()
  local env = os.getenv("LUNET_CRYPTO_LIB")
  if env and env ~= "" then return env end
  local suffix, prefix = "so", "lib"
  if package.config:sub(1, 1) == "\\" then
    -- Windows: the cdylib is lunet_crypto.dll (no "lib" prefix)
    suffix, prefix = "dll", ""
  else
    local ok_popen, uname = pcall(io.popen, "uname -s 2>/dev/null")
    if ok_popen and uname then
      local sys = uname:read("*l") or ""
      uname:close()
      if sys == "Darwin" then suffix = "dylib" end
    end
  end
  local script = debug.getinfo(2, "S").source
  local dir = script:match("^@(.+)/[^/]+$") or "."
  for _, p in ipairs({
    dir .. "/target/release/" .. prefix .. "lunet_crypto." .. suffix,
    dir .. "/" .. prefix .. "lunet_crypto." .. suffix,
  }) do
    local f = io.open(p, "rb")
    if f then f:close(); return p end
  end
  error("lunet.sodium: cannot find " .. prefix .. "lunet_crypto." .. suffix, 3)
end

-- THE dylib handle: every primitive binds through it, so the lookup can
-- never be captured by a user-loaded libsodium in the same process.
local C = ffi.load(find_lib())

local len_box = ffi.new("size_t[1]")

local function last_error()
  local p = C.lunet_crypto_last_error(len_box)
  if p == nil then return "lunet.sodium: unknown error" end
  return ffi.string(p, tonumber(len_box[0]))
end

local function check_string(v, name)
  if type(v) ~= "string" then
    error(("bad argument '%s' (string expected, got %s)"):format(name, type(v)), 3)
  end
  return v
end

local function check_count(v, name)
  if type(v) ~= "number" or v ~= v or v % 1 ~= 0 or v < 0 then
    error(("bad argument '%s' (expected a non-negative integer, got %s)")
      :format(name, tostring(v)), 3)
  end
  return v
end

local M = {}

--- Digest size in bytes of both `sha256` and `hmac_sha256` outputs (32).
--- Read from this loader's allocation, which the Rust side writes with
--- the linked library's digest  -  the constant can never drift.
M.BYTES = BYTES

--- One-shot SHA-256. Returns the raw 32-byte digest as a string.
--- Malformed arguments raise; an operational failure (libsodium init)
--- returns nil, message.
---@param data string Data to hash
---@return string|nil digest 32 raw bytes, nil plus a message on operational failure
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local d = sodium.sha256("abc")
---```
function M.sha256(data)
  data = check_string(data, "data")
  local out = ffi.new("uint8_t[?]", BYTES)
  local rc = C.lunet_sodium_sha256(data, #data, out)
  if rc == RC_INVAL then error(last_error(), 2) end
  if rc ~= RC_OK then return nil, last_error() end
  return ffi.string(out, BYTES)
end

--- One-shot HMAC-SHA-256  -  the JWT HS256 primitive. `key` must be
--- exactly 32 bytes (libsodium's fixed HMAC-SHA-256 key size; a wrong
--- length raises). Returns the raw 32-byte tag as a string.
---
--- SECURITY: the key crosses the FFI as ordinary Lua string data  - 
--- unguarded. See docs/SODIUM.md.
---@param data string Data to authenticate
---@param key string Exactly 32 bytes
---@return string|nil tag 32 raw bytes, nil plus a message on operational failure
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local sig = sodium.hmac_sha256(payload, key32)
---```
function M.hmac_sha256(data, key)
  data = check_string(data, "data")
  key = check_string(key, "key")
  local out = ffi.new("uint8_t[?]", BYTES)
  local rc = C.lunet_sodium_hmac_sha256(data, #data, key, #key, out)
  if rc == RC_INVAL then error(last_error(), 2) end
  if rc ~= RC_OK then return nil, last_error() end
  return ffi.string(out, BYTES)
end

--- Draw `n` unpredictable bytes from the cdylib's CSPRNG. `n` is a
--- non-negative integer; 0 returns the empty string. Returns the raw
--- bytes as a string.
---@param n integer Number of bytes to draw
---@return string|nil bytes n raw bytes, nil plus a message on operational failure
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local nonce = sodium.random(12)
---```
function M.random(n)
  n = check_count(n, "n")
  if n == 0 then return "" end
  local out = ffi.new("uint8_t[?]", n)
  local rc = C.lunet_sodium_randombytes(out, n)
  if rc == RC_INVAL then error(last_error(), 2) end
  if rc ~= RC_OK then return nil, last_error() end
  return ffi.string(out, n)
end

--- Base64 variant selection. The values are libsodium's own macro
--- values, mirrored here and in the Rust constants.
--- URLSAFE_NO_PADDING (7) is the JWT profile: tokens travel in headers
--- and never carry `=`.
M.BASE64_VARIANT_ORIGINAL = 1
M.BASE64_VARIANT_ORIGINAL_NO_PADDING = 3
M.BASE64_VARIANT_URLSAFE = 5
M.BASE64_VARIANT_URLSAFE_NO_PADDING = 7

--- Encoded length of `n` raw bytes under ANY variant, NUL included: the
--- linked library's `sodium_base64_ENCODE_LEN` formula. The 4-byte slack
--- covers the per-group padding maximum across all variants.
local function base64_encoded_len(n)
  return math.floor(n / 3) * 4 + 5
end

--- Decoded upper bound of `n` encoded bytes under ANY variant: every 4
--- encoded characters carry at most 3 raw bytes, plus headroom for the
--- trailing group.
local function base64_decoded_len(n)
  return (math.floor(n / 4) + 1) * 3
end

local function check_variant(v, name)
  check_count(v, name)
  if v ~= M.BASE64_VARIANT_ORIGINAL and
     v ~= M.BASE64_VARIANT_ORIGINAL_NO_PADDING and
     v ~= M.BASE64_VARIANT_URLSAFE and
     v ~= M.BASE64_VARIANT_URLSAFE_NO_PADDING then
    error(("bad argument '%s' (unknown base64 variant %d)"):format(name, v), 3)
  end
  return v
end

--- Encode `data` with the linked library's own base64 under `variant`
--- (one of the BASE64_VARIANT_* constants above; an unknown variant
--- raises  -  a bug in the calling script). URLSAFE_NO_PADDING is the JWT
--- profile. Returns the encoded text.
---
--- SECURITY: base64 crosses no secrets  -  a plain, stateless transform;
--- bytes that are secret remain secret while encoded.
---@param data string Bytes to encode
---@param variant integer One of the BASE64_VARIANT_* constants
---@return string|nil b64 Encoded text, nil plus a message on operational failure
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local b64 = sodium.base64_encode(data, sodium.BASE64_VARIANT_URLSAFE_NO_PADDING)
---```
function M.base64_encode(data, variant)
  data = check_string(data, "data")
  variant = check_variant(variant, "variant")
  local needed = base64_encoded_len(#data)
  local out = ffi.new("uint8_t[?]", needed)
  local rc = C.lunet_sodium_base64_encode(data, #data, variant, out, needed)
  if rc == RC_INVAL then error(last_error(), 2) end
  if rc ~= RC_OK then return nil, last_error() end
  return ffi.string(out)
end

--- Decode base64 back to bytes with the linked library's own transform
--- under the same `variant` selection. Decode failures  -  malformed input
--- for the variant, unknown variant, or trailing garbage after the
--- payload  -  raise with the library's own diagnostic (a bug in the
--- calling script). Returns the decoded bytes; the result is binary, so
--- length  -  not a NUL  -  says where it ends.
---@param data string Encoded text
---@param variant integer One of the BASE64_VARIANT_* constants
---@return string|nil bytes Decoded bytes, nil plus a message on operational failure
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local sodium = require("lunet.sodium")
---local bin = sodium.base64_decode(token, sodium.BASE64_VARIANT_URLSAFE_NO_PADDING)
---```
function M.base64_decode(data, variant)
  data = check_string(data, "data")
  variant = check_variant(variant, "variant")
  if #data == 0 then return "" end
  local out = ffi.new("uint8_t[?]", base64_decoded_len(#data))
  local written = ffi.new("size_t[1]")
  local rc = C.lunet_sodium_base64_decode(data, #data, variant, out,
    base64_decoded_len(#data), written)
  if rc == RC_INVAL then error(last_error(), 2) end
  if rc ~= RC_OK then return nil, last_error() end
  return ffi.string(out, tonumber(written[0]))
end

local PWHASH_DEFAULTS = { opslimit = 2, memlimit = 67108864 }

--- Argon2id password hashing (libsodium crypto_pwhash_str). Hashes
--- `password` with the interactive limits by default; `opts` may
--- override `opslimit` and/or `memlimit` (bytes). Unknown opts keys,
--- wrong types and malformed arguments raise; an operational failure
--- returns nil plus message. The salt is embedded in the returned
--- self-describing string.
---@param password string Password to hash
---@param opts table|nil Optional overrides: `opslimit` (default 2),
---   `memlimit` (default 67108864 bytes)
---@return string|nil hash Self-describing Argon2id hash string
---@return string|nil error Set only on operational failure
function M.pwhash_str(password, opts)
  password = check_string(password, "password")
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then
    error(("bad argument 'opts' (table expected, got %s)"):format(type(opts)), 2)
  end
  local opslimit = opts.opslimit
  if opslimit == nil then opslimit = PWHASH_DEFAULTS.opslimit end
  local memlimit = opts.memlimit
  if memlimit == nil then memlimit = PWHASH_DEFAULTS.memlimit end
  for k, _ in pairs(opts) do
    if k ~= "opslimit" and k ~= "memlimit" then
      error(("bad argument 'opts' (unknown option '%s')"):format(k), 2)
    end
  end
  opslimit = check_count(opslimit, "opts.opslimit")
  memlimit = check_count(memlimit, "opts.memlimit")
  local need = 128
  local out = ffi.new("uint8_t[?]", need)
  local rc = C.lunet_sodium_pwhash_str(password, #password, opslimit,
    memlimit, out, need)
  if rc == RC_INVAL then error(last_error(), 2) end
  if rc ~= RC_OK then return nil, last_error() end
  return ffi.string(out)
end

--- Verify `password` against a self-describing Argon2id hash string.
--- Returns true on match, false on mismatch or malformed hash. Malformed
--- arguments raise; an operational failure returns nil, message.
---@param password string Password to verify
---@param hash string Self-describing hash string
---@return boolean|nil ok True on match, false on mismatch, nil on operational failure
---@return string|nil error Set only on operational failure
function M.pwhash_str_verify(password, hash)
  password = check_string(password, "password")
  hash = check_string(hash, "hash")
  local rc = C.lunet_sodium_pwhash_str_verify(hash, #hash, password, #password)
  if rc == RC_INVAL then error(last_error(), 2) end
  if rc == RC_ERR then return nil, last_error() end
  return rc == RC_OK
end

return M
