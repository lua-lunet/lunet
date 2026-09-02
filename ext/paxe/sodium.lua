-- lunet.sodium: a MINIMAL libsodium primitive surface, loaded from the
-- SAME cdylib as lunet.paxe through the LuaJIT FFI (the jsonic / paxe
-- loader model). Exactly three primitives: SHA-256, HMAC-SHA-256 (the
-- JWT HS256 primitive) and randombytes — see docs/SODIUM.md.
--
-- WHY THIS EXISTS: liblunet_paxe already statically links libsodium, so
-- every binary-archive consumer carries the bytes for these primitives
-- inside a dylib it already ships. They were previously unreachable (the
-- static sodium symbols are not exported), which forced users to load a
-- SECOND libsodium (homebrew, distro) — two sodiums in one process, with
-- dlsym(RTLD_DEFAULT) ambiguity. This module binds through the dylib
-- HANDLE returned by ffi.load below, never through ffi.C / RTLD_DEFAULT,
-- so a user-owned libsodium in the same process can never capture the
-- lookup.
--
-- ABI PROMISE (deliberately narrow): the three lunet_sodium_* symbols
-- below. No wholesale export of the libsodium namespace — the vendored
-- sodium version is not a public ABI promise, and a full export would be
-- a symbol-collision hazard with user-loaded sodiums. No streaming or
-- incremental variants; no keyring or guarded key memory (that remains
-- PAXE's job — lunet.paxe.keystore_set).
--
-- ERROR CONVENTION (same shape as lunet.paxe): malformed arguments RAISE
-- a Lua error (they are bugs in the calling script); operational
-- failures (libsodium could not be initialised) return nil, message.
-- TYPE CHECKS RUN HERE: by the time a value crosses the FFI its Lua type
-- is invisible to Rust, so this module validates every argument before
-- the call, exactly like ext/paxe/paxe.lua does.
--
-- SECURITY BOUNDARY (docs/SODIUM.md states it too): stateless hashing
-- crosses no secrets; the HMAC key is ordinary Lua string data and DOES
-- cross the FFI unguarded — a documented boundary, the same posture as
-- the paxe keystore notes in docs/PAXE.md.

local ffi = require("ffi")

ffi.cdef[[
  int lunet_sodium_sha256(const uint8_t* input, size_t input_len, uint8_t* out);
  int lunet_sodium_hmac_sha256(const uint8_t* input, size_t input_len,
                               const uint8_t* key, size_t key_len, uint8_t* out);
  int lunet_sodium_randombytes(uint8_t* out, size_t out_len);
  const uint8_t* lunet_paxe_last_error(size_t* len);
]]

-- Return codes, mirroring src/lib.rs (shared with the paxe ABI).
local RC_OK = 0     -- success
local RC_ERR = -1   -- operational failure -> nil, last_error()
local RC_INVAL = -2 -- malformed argument -> raise last_error()

-- Digest/tag size of both hash primitives (crypto_hash_sha256_BYTES and
-- crypto_auth_hmacsha256_BYTES are both 32 in every libsodium release).
local BYTES = 32

-- Find the paxe cdylib exactly like ext/paxe/paxe.lua does: environment
-- override first, then the loader's own directory and its cargo output
-- tree. The returned handle is what every symbol below binds through —
-- never ffi.C, never a bare name.
local function find_lib()
  local env = os.getenv("LUNET_SODIUM_LIB") or os.getenv("LUNET_PAXE_LIB")
  if env and env ~= "" then return env end
  local suffix, prefix = "so", "lib"
  if package.config:sub(1, 1) == "\\" then
    -- Windows: the cdylib is lunet_paxe.dll (no "lib" prefix)
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
    dir .. "/target/release/" .. prefix .. "lunet_paxe." .. suffix,
    dir .. "/" .. prefix .. "lunet_paxe." .. suffix,
  }) do
    local f = io.open(p, "rb")
    if f then f:close(); return p end
  end
  error("lunet.sodium: cannot find " .. prefix .. "lunet_paxe." .. suffix, 3)
end

-- THE dylib handle: every primitive binds through it, so the lookup can
-- never be captured by a user-loaded libsodium in the same process.
local C = ffi.load(find_lib())

local len_box = ffi.new("size_t[1]")

local function last_error()
  local p = C.lunet_paxe_last_error(len_box)
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
--- the linked library's digest — the constant can never drift.
M.BYTES = BYTES

--- One-shot SHA-256. Returns the raw 32-byte digest as a string.
--- Malformed arguments raise; an operational failure (libsodium init)
--- returns nil, message.
---@param data string Data to hash
---@return string digest 32 raw bytes
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

--- One-shot HMAC-SHA-256 — the JWT HS256 primitive. `key` must be
--- exactly 32 bytes (libsodium's fixed HMAC-SHA-256 key size; a wrong
--- length raises). Returns the raw 32-byte tag as a string.
---
--- SECURITY: the key crosses the FFI as ordinary Lua string data —
--- unguarded, unlike PAXE keystore material. See docs/SODIUM.md.
---@param data string Data to authenticate
---@param key string Exactly 32 bytes
---@return string tag 32 raw bytes
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

--- Draw `n` unpredictable bytes from the SAME CSPRNG PAXE uses (never
--- mix two RNGs in one process). `n` is a non-negative integer; 0
--- returns the empty string. Returns the raw bytes as a string.
---@param n integer Number of bytes to draw
---@return string bytes n raw bytes
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

return M
