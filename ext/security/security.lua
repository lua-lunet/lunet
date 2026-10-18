-- lunet.security: authenticated-token helpers for lunet applications —
-- HMAC-SHA-256 sign/verify, base64url, and JWT HS256 (encode / decode).
--
-- ONE flat module, pure Lua, opt-in like the database drivers. It owns
-- NO primitives of its own: every byte-level operation goes through the
-- EXISTING lunet.sodium surface (HMAC-SHA-256 and the URLSAFE base64
-- variants, both backed by liblunet_paxe — libsodium statically linked)
-- and claims JSON goes through the EXISTING lunet.jsonic. Nothing here
-- hashes, pads, or parses on its own beyond gluing the pieces.
--
-- DEPENDENCY CONTRACT (docs/SECURITY.md states it too):
--   * lunet.sodium — required at load time (so a missing liblunet_paxe
--     fails the require itself, never mid-request). In a release archive
--     both loaders sit side by side in lunet/ and resolve via the
--     runtime's lunet/?.lua path entry; the operator's only system-level
--     obligation is libsodium, which PAXE already links statically.
--   * lunet.jsonic — required by jwt.* only, loaded on first use, so
--     crypto.* works everywhere lunet.sodium works (jsonic's native
--     decoder does not ship on the Windows archives yet).
--
-- ERROR CONVENTION (same shape as lunet.sodium): malformed arguments
-- RAISE a Lua error — they are bugs in the calling script (a nil
-- payload, an empty secret). Token CONTENT is untrusted input, not a
-- bug, so jwt.decode reports it as nil plus an error string that names
-- the failure kind: malformed / sig / exp. Operational failures
-- (libsodium could not be initialised) surface as nil, message from
-- sign/encode and are re-raised from the boolean verify.
--
-- KEY HANDLING (the reconciled design, stated): libsodium's
-- crypto_auth_hmacsha256 fixes the HMAC-SHA-256 key at exactly 32
-- bytes, and lunet.sodium deliberately refuses any other length rather
-- than silently pad or truncate. A 32-byte key is used exactly as given
-- (known-answer vectors apply unchanged); any other non-empty key is
-- first reduced to 32 bytes with SHA-256 — a deterministic subkey
-- derivation. Keys longer than the HMAC block size (64 bytes) derive
-- exactly the tag plain HMAC-SHA-256 would produce (RFC 2104 hashes
-- such keys too); shorter keys are hashed instead of zero-padded, which
-- never silently discards secret material the way truncation would.

local sodium = require("lunet.sodium")
local bit = require("bit")

local M = {}
M.crypto = {}
M.jwt = {}

local crypto = M.crypto
local jwt = M.jwt

-- Digest/tag size of HMAC-SHA-256 (lunet.sodium.BYTES).
local TAG_BYTES = 32

-- lunet.jsonic is jwt-only and loaded on first use: the require itself
-- succeeds without the native decoder (encode is pure Lua) and the
-- decoder is what needs liblunet_jsonic.
local jsonic_mod
local function claims_json()
  if not jsonic_mod then
    local ok, mod = pcall(require, "lunet.jsonic")
    if not ok then
      error("lunet.security: jwt claims need lunet.jsonic, which could not be loaded: "
        .. tostring(mod), 2)
    end
    jsonic_mod = mod
  end
  return jsonic_mod
end

local function check_string(v, name)
  if type(v) ~= "string" then
    error(("bad argument '%s' (string expected, got %s)"):format(name, type(v)), 3)
  end
  return v
end

-- Constant-time equality over equal-length strings: every byte position
-- contributes to one accumulated difference, so the work done does not
-- depend on where (or whether) the strings diverge. The loop count is
-- fixed by the tag length. Length itself is not hidden — comparing
-- lengths is unavoidable in Lua and leaks nothing an attacker cannot
-- already see (the tag length is public).
local function ct_equal(a, b)
  local diff = 0
  for i = 1, #a do
    diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
  end
  return diff == 0
end

-- The HMAC-SHA-256 sign of `data` under `key`: the raw 32-byte tag, or
-- nil plus a message on operational failure (libsodium could not be
-- initialised). A 32-byte key is used as-is; any other non-empty key is
-- first reduced to 32 bytes with SHA-256 (see the header note).
---
---HMAC-SHA-256 over the existing lunet.sodium primitive.
---
---`key` may be any non-empty string: a 32-byte key is used exactly as
---given (known-answer vectors apply unchanged), any other length is
---first reduced to 32 bytes with SHA-256 — a deterministic subkey
---derivation (keys longer than the HMAC block size derive exactly the
---plain HMAC-SHA-256 tag; shorter keys are hashed, never truncated or
---zero-padded). Malformed arguments raise; an operational failure
---(libsodium init) returns nil, message.
---@param data string Data to authenticate
---@param key string Non-empty secret key
---@return string tag 32 raw tag bytes
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local security = require("lunet.security")
---local tag = security.crypto.sign("payload", secret)
---```
function crypto.sign(data, key)
  data = check_string(data, "data")
  key = check_string(key, "key")
  if #key == 0 then
    error("bad argument 'key' (must be a non-empty string)", 2)
  end
  local work = key
  if #work ~= TAG_BYTES then
    local derived, derr = sodium.sha256(key)
    if not derived then return nil, derr end
    work = derived
  end
  return sodium.hmac_sha256(data, work)
end

---Verify the HMAC-SHA-256 tag of `data` under `key` in constant time:
---computes the expected tag with `sign` and compares it against `sig`
---byte-by-byte through an accumulated XOR difference (the work done
---does not depend on where the strings diverge). Returns true or
---false; a `sig` of any other length than 32 bytes is simply false.
---Malformed arguments raise; an operational failure (libsodium init)
---is re-raised rather than silently reported as a bad signature.
---@param data string Data that was signed
---@param key string Non-empty secret key (as passed to sign)
---@param sig string The 32-byte tag to check
---@return boolean ok True when the tag matches
---@usage
---```lua
---local security = require("lunet.security")
---assert(security.crypto.verify("payload", secret, tag))
---```
function crypto.verify(data, key, sig)
  data = check_string(data, "data")
  key = check_string(key, "key")
  sig = check_string(sig, "sig")
  if #key == 0 then
    error("bad argument 'key' (must be a non-empty string)", 2)
  end
  local tag, err = crypto.sign(data, key)
  if not tag then error(err, 2) end
  if #sig ~= #tag then return false end
  return ct_equal(sig, tag)
end

---Encode `data` as unpadded base64url (the JWT profile) using the
---existing lunet.sodium URLSAFE base64 variant — the URL-safe alphabet
---(- and _) with no = padding. Malformed arguments raise with the
---underlying library's diagnostic, like lunet.sodium itself.
---@param data string Bytes to encode
---@return string b64 Encoded text
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local security = require("lunet.security")
---local seg = security.crypto.b64url_encode('{"alg":"HS256"}')
---```
function crypto.b64url_encode(data)
  data = check_string(data, "data")
  return sodium.base64_encode(data, sodium.BASE64_VARIANT_URLSAFE_NO_PADDING)
end

---Decode unpadded base64url back to bytes using the existing
---lunet.sodium URLSAFE base64 variant. Malformed input raises with the
---underlying library's diagnostic (the same convention as
---lunet.sodium.base64_decode) — jwt.decode converts that into its
---named "malformed" error because token bytes are untrusted input,
---while direct callers keep the raise.
---@param data string Encoded text
---@return string bytes Decoded bytes
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local security = require("lunet.security")
---local raw = security.crypto.b64url_decode("Zm9vYg")
---```
function crypto.b64url_decode(data)
  data = check_string(data, "data")
  return sodium.base64_decode(data, sodium.BASE64_VARIANT_URLSAFE_NO_PADDING)
end

-- ---------------------------------------------------------------------------
-- JWT (HS256)
-- ---------------------------------------------------------------------------

-- Named decode errors. The kind is the word after the module prefix, so
-- callers can match on it: malformed / sig / exp.
local ERR = {
  token = "lunet.security.jwt: malformed: token must be a non-empty string",
  shape = "lunet.security.jwt: malformed: expected header.payload.signature as three base64url segments",
  sig_b64 = "lunet.security.jwt: malformed: signature segment is not valid base64url",
  sig = "lunet.security.jwt: sig: signature verification failed",
  header_b64 = "lunet.security.jwt: malformed: header segment is not valid base64url",
  header = "lunet.security.jwt: malformed: header is not a JSON object",
  alg = "lunet.security.jwt: malformed: header alg is not HS256",
  payload_b64 = "lunet.security.jwt: malformed: payload segment is not valid base64url",
  payload = "lunet.security.jwt: malformed: payload is not a JSON object",
  exp_type = "lunet.security.jwt: malformed: exp claim is not a number",
  exp = "lunet.security.jwt: exp: token expired",
}

---Encode a JWT (HS256). The header is fixed at {alg="HS256",
---typ="JWT"} (encoded in a canonical byte order, so the header segment
---is always the same); the claims are the JSON of `payload` via
---lunet.jsonic. Signature verification is the decode-side twin, so a
---token from encode always round-trips through decode.
---
---exp handling (the reconciled design, stated): `opts.expires_in`
---(positive integer seconds) injects exp = now + expires_in on a COPY
---of the payload — the caller's table is never mutated, and an exp set
---this way wins over one already in the payload. Without expires_in the
---payload passes through unchanged, exp claim or not. A token without
---an exp claim never expires on decode.
---
---Malformed arguments raise (a nil payload, an empty secret); JSON
---encoding failures (cycles, unsupported types) raise from jsonic.
---@param payload table Claims table
---@param secret string Non-empty secret key
---@param opts table|nil Optional table; expires_in (integer seconds) injects the exp claim
---@return string token The compact JWT
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local security = require("lunet.security")
---local token = security.jwt.encode({ sub = "u1" }, secret, { expires_in = 3600 })
---```
function jwt.encode(payload, secret, opts)
  if type(payload) ~= "table" then
    error("bad argument 'payload' (table expected, got " .. type(payload) .. ")", 2)
  end
  secret = check_string(secret, "secret")
  if #secret == 0 then
    error("bad argument 'secret' (must be a non-empty string)", 2)
  end
  if opts ~= nil and type(opts) ~= "table" then
    error("bad argument 'opts' (table expected, got " .. type(opts) .. ")", 2)
  end
  local claims = payload
  if opts and opts.expires_in ~= nil then
    local ttl = opts.expires_in
    if type(ttl) ~= "number" or ttl ~= ttl or ttl % 1 ~= 0 or ttl <= 0 then
      error("bad argument 'opts' (expires_in must be a positive integer number of seconds)", 2)
    end
    claims = {}
    for k, v in pairs(payload) do claims[k] = v end
    claims.exp = os.time() + ttl
  end
  local json = claims_json()
  local header_b64 = crypto.b64url_encode(
    json.encode({ alg = "HS256", typ = "JWT" }, { keyorder = { "alg", "typ" } }))
  local payload_b64 = crypto.b64url_encode(json.encode(claims))
  local message = header_b64 .. "." .. payload_b64
  local sig, err = crypto.sign(message, secret)
  if not sig then return nil, err end
  return message .. "." .. crypto.b64url_encode(sig)
end

---Decode a JWT (HS256) and return its claims table. The token content
---is untrusted input, so every content failure is reported as nil plus
---an error string that names the kind of failure:
---
---  * malformed — not three dot-separated base64url segments, a segment
---    that does not decode, a header/payload that is not a JSON object,
---    a header whose alg is not HS256 (the alg-confusion defence: a
---    token is only ever accepted under the algorithm it was issued
---    with), or an exp claim that is not a number.
---  * sig — the signature over header.payload does not match, compared
---    in constant time.
---  * exp — the token carries an exp claim that is strictly before the
---    current time. A token without an exp claim never expires.
---
---The signature is verified before any JSON is parsed, so no byte of
---the token body influences anything but the bytes the MAC covers.
---Malformed ARGUMENTS (a non-string secret, an empty secret) raise —
---those are bugs in the calling script, not attacker input.
---@param token string The compact JWT (as produced by encode)
---@param secret string Non-empty secret key (as passed to encode)
---@return table payload Claims table
---@return string|nil error nil on success; otherwise names the failure
---@usage
---```lua
---local security = require("lunet.security")
---local claims, err = security.jwt.decode(token, secret)
---if not claims then return nil, err end
---```
function jwt.decode(token, secret)
  secret = check_string(secret, "secret")
  if #secret == 0 then
    error("bad argument 'secret' (must be a non-empty string)", 2)
  end
  if type(token) ~= "string" or #token == 0 then
    return nil, ERR.token
  end
  local header_b64, payload_b64, sig_b64 = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
  if not header_b64 then
    return nil, ERR.shape
  end
  local json = claims_json()

  local ok_sig, sig = pcall(crypto.b64url_decode, sig_b64)
  if not ok_sig then
    return nil, ERR.sig_b64
  end
  local message = header_b64 .. "." .. payload_b64
  local expected, serr = crypto.sign(message, secret)
  if not expected then return nil, serr end
  if #sig ~= #expected or not ct_equal(sig, expected) then
    return nil, ERR.sig
  end

  local ok_hb, header_json = pcall(crypto.b64url_decode, header_b64)
  if not ok_hb then
    return nil, ERR.header_b64
  end
  local ok_h, header = pcall(json.decode, header_json)
  if not ok_h or type(header) ~= "table" then
    return nil, ERR.header
  end
  if header.alg ~= "HS256" then
    return nil, ERR.alg
  end

  local ok_pb, payload_json = pcall(crypto.b64url_decode, payload_b64)
  if not ok_pb then
    return nil, ERR.payload_b64
  end
  local ok_p, claims = pcall(json.decode, payload_json)
  if not ok_p or type(claims) ~= "table" then
    return nil, ERR.payload
  end

  if claims.exp ~= nil then
    if type(claims.exp) ~= "number" then
      return nil, ERR.exp_type
    end
    if claims.exp < os.time() then
      return nil, ERR.exp
    end
  end
  return claims
end

return M
