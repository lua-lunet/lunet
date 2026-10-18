---@meta

---lunet.security — authenticated-token helpers: HMAC-SHA-256
---sign/verify, base64url, and JWT HS256.
---
---ONE flat, pure-Lua module over the EXISTING primitives: every
---byte-level operation goes through lunet.sodium (HMAC-SHA-256 and the
---URLSAFE base64 variants, both backed by liblunet_paxe — libsodium
---statically linked) and claims JSON goes through lunet.jsonic.
---Requires lunet.sodium at load time; lunet.jsonic is jwt-only and
---loaded on first use. See `docs/SECURITY.md`.
---
---Error convention (same shape as lunet.sodium): malformed arguments
---raise (bugs in the calling script); token CONTENT is untrusted input
---and jwt.decode reports it as nil plus an error string naming the
---failure kind: malformed / sig / exp.
---
---Key handling: a 32-byte key is used exactly as given (known-answer
---vectors apply unchanged); any other non-empty key is first reduced
---to 32 bytes with SHA-256 — a deterministic subkey derivation (keys
---longer than the HMAC block size derive exactly the plain
---HMAC-SHA-256 tag; shorter keys are hashed, never truncated).
local security = {}

---HMAC/base64url helpers over lunet.sodium.
---@class lunet.security.crypto
local crypto = {}

---HMAC-SHA-256 over the existing lunet.sodium primitive.
---
---`key` may be any non-empty string: a 32-byte key is used exactly as
---given, any other length is first reduced to 32 bytes with SHA-256.
---Malformed arguments raise; an operational failure (libsodium init)
---returns nil, message.
---@param data string Data to authenticate
---@param key string Non-empty secret key
---@return string tag 32 raw tag bytes
---@return string|nil error Set only on operational failure
---@usage
---```lua
---local security = require("lunet.security")
---local tag = security.crypto.sign("payload", secret)
---```
function crypto.sign(data, key) end

---Verify the HMAC-SHA-256 tag of `data` under `key` in constant time:
---computes the expected tag and compares it byte-by-byte through an
---accumulated XOR difference. A `sig` of any other length than 32
---bytes is simply false. Malformed arguments raise; an operational
---failure (libsodium init) is re-raised rather than silently reported
---as a bad signature.
---@param data string Data that was signed
---@param key string Non-empty secret key (as passed to sign)
---@param sig string The 32-byte tag to check
---@return boolean ok True when the tag matches
---@usage
---```lua
---local security = require("lunet.security")
---assert(security.crypto.verify("payload", secret, tag))
---```
function crypto.verify(data, key, sig) end

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
function crypto.b64url_encode(data) end

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
function crypto.b64url_decode(data) end

---JWT HS256 encode/decode over lunet.jsonic claims.
---@class lunet.security.jwt
local jwt = {}

---Encode a JWT (HS256). The header is fixed at {alg="HS256",
---typ="JWT"} (encoded in a canonical byte order, so the header segment
---is always the same); the claims are the JSON of `payload` via
---lunet.jsonic.
---
---exp handling: `opts.expires_in` (positive integer seconds) injects
---exp = now + expires_in on a COPY of the payload — the caller's table
---is never mutated, and an exp set this way wins over one already in
---the payload. Without expires_in the payload passes through
---unchanged, exp claim or not. A token without an exp claim never
---expires on decode.
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
function jwt.encode(payload, secret, opts) end

---Decode a JWT (HS256) and return its claims table. The token content
---is untrusted input, so every content failure is reported as nil plus
---an error string that names the kind of failure: `malformed` (not
---three dot-separated base64url segments, a segment that does not
---decode, a header/payload that is not a JSON object, a header whose
---alg is not HS256, or an exp claim that is not a number), `sig` (the
---signature does not match, compared in constant time), or `exp` (the
---token carries an exp claim strictly before the current time; a token
---without exp never expires). The signature is verified before any
---JSON is parsed. Malformed ARGUMENTS (a non-string or empty secret)
---raise — those are bugs in the calling script, not attacker input.
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
function jwt.decode(token, secret) end

---@type lunet.security.crypto
security.crypto = crypto

---@type lunet.security.jwt
security.jwt = jwt

return security
