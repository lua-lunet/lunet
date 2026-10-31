# Security: HMAC + JWT Extension Module

`lunet.security` is an opt-in Lua wrapper that gives lunet applications the
authenticated-token layer every web app needs: HMAC-SHA-256 sign/verify,
base64url helpers, and JWT HS256 (`encode` / `decode`).

The virtue is whose crypto it is: every cryptographic byte-level operation is
libsodium's, reached through the FFI (`liblunet_crypto`, via `lunet.sodium`) - 
the wrapper implements no crypto itself. The one composition it does in Lua is
HMAC-SHA-256 built on `lunet.sodium.sha256` per RFC 2104 (a key-padding step - 
see "Key handling" below), and claims JSON goes through `lunet.jsonic`.

## Overview

- `security.crypto` - HMAC-SHA-256 `sign` / `verify` (constant-time compare)
  and unpadded base64url `b64url_encode` / `b64url_decode`, all over
  `lunet.sodium`.
- `security.jwt` - HS256 `encode` / `decode` over `security.crypto` +
  `lunet.jsonic`: canonical `{alg="HS256", typ="JWT"}` header, type-checked
  header and claims, constant-time signature verification, `exp` enforced -
  plus `bearer`, the extract-and-verify helper for `Authorization` headers.

## Requirements and loading

The extension declares what it needs, the operator installs it:

| Dependency | When | Why |
|------------|------|-----|
| libsodium (via `liblunet_crypto`) | Always - `lunet.sodium` is required at load time | HMAC-SHA-256 and base64 primitives |
| `lunet.jsonic` | JWT only - loaded on first use | Claims JSON encode/decode; the loader ships in the archive beside this module (its native decoder is POSIX-only for now) |

In a release archive the loaders sit side by side in `lunet/` and resolve
through the runtime's `lunet/?.lua` path entry - see
[docs/RELEASE-LAYOUT.md](RELEASE-LAYOUT.md). From the repository, or in any
LuaJIT program, load the files directly:

```lua
local security = require("lunet.security")
local crypto, jwt = security.crypto, security.jwt
```

`require("lunet.security")` fails outright when `lunet.sodium` cannot find
`liblunet_crypto` (build it with `xmake build-crypto`); a missing `lunet.jsonic`
only breaks `jwt.*`, on first use, with an error naming the dependency.

## Lua API (`lunet.security`)

### `security.crypto.sign(data, key) -> tag`

HMAC-SHA-256 over the RAW secret octets, composed per RFC 2104 on
`lunet.sodium.sha256`. Returns the raw 32-byte tag - bit-identical to plain
HMAC-SHA-256 for every key length.

`key` may be any non-empty string - see "Key handling" below. Malformed
arguments raise; an operational failure (libsodium could not be initialised)
returns `nil, message`.

### `security.crypto.verify(data, key, sig) -> ok`

Constant-time verification: computes the expected tag and compares it against
`sig` byte-by-byte through an accumulated XOR difference - the work done does
not depend on where the strings diverge. A `sig` of any other length than 32
bytes is simply `false`. Returns `true` or `false`; an operational failure is
re-raised rather than silently reported as a bad signature.

### `security.crypto.b64url_encode(data) -> b64`

Encode as unpadded base64url - the JWT profile: the URL-safe alphabet (`-`,
`_`) and no `=` padding - using `lunet.sodium`'s URLSAFE variant. Malformed
arguments raise with the underlying library's diagnostic, like `lunet.sodium`
itself.

### `security.crypto.b64url_decode(data) -> bytes`

Decode unpadded base64url back to bytes through the same variant. Malformed
input raises with the underlying library's diagnostic (the
`lunet.sodium.base64_decode` convention) - `jwt.decode` converts that into
its named `malformed` error because token bytes are untrusted input, while
direct callers keep the raise.

### `security.jwt.encode(payload, secret, opts?) -> token`

Encode a compact JWT. The header is fixed at `{alg="HS256", typ="JWT"}`
(encoded in a canonical byte order, so the header segment is always
`eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9`); the claims are the JSON of
`payload` via `lunet.jsonic`.

`opts.expires_in` (positive integer seconds) injects `exp = now +
expires_in` on a **copy** of the payload - the caller's table is never
mutated, and an `exp` set this way wins over one already in the payload.
Without `expires_in` the payload passes through unchanged, `exp` claim or
not.

Malformed arguments raise (a nil payload, an empty secret); JSON encoding
failures (cycles, unsupported types) raise from `lunet.jsonic`.

### `security.jwt.decode(token, secret) -> claims, err`

Decode and verify a compact JWT, returning the claims table, or `nil` plus an
error string that names the failure kind:

| Kind | Error string | Meaning |
|------|--------------|---------|
| `malformed` | `lunet.security.jwt: malformed: ...` | Not three dot-separated base64url segments; a segment that does not decode; header or claims that are not a JSON object; a header whose `alg` is not `HS256`; an `exp` claim that is not a number |
| `sig` | `lunet.security.jwt: sig: signature verification failed` | The signature over `header.payload` does not match - compared in constant time |
| `exp` | `lunet.security.jwt: exp: token expired` | The token carries an `exp` claim strictly before the current time |

The signature is verified **before** any JSON is parsed, so no byte of the
token body influences anything but the bytes the MAC covers. The `alg` check
runs after the signature check and refuses anything but `HS256` - an
alg-confusion token (for example a `{"alg":"none"}` header) is rejected as
`malformed` even when the signature over it is genuinely valid.

### `security.jwt.bearer(authorization, secret, schemes) -> claims, kind`

Extract-and-verify for an `Authorization` header: the mechanism, not the
policy. `schemes` names the scheme words the caller is willing to accept -
a single string or a non-empty array of strings - matched case-insensitively
against the header's scheme word (one-or-more separator spaces, trailing
whitespace tolerated), then the token is decoded with `jwt.decode`, mapping
every failure to a short kind word so each app keeps its own error messages,
statuses, and fallback identities:

```lua
-- Token-only, as the RealWorld spec mandates:
local claims, kind = security.jwt.bearer(auth_header, secret, "Token")

-- Or several, when the app genuinely wants both:
local claims, kind = security.jwt.bearer(auth_header, secret, { "Bearer", "Token" })
```

`schemes` is required: there is no default accepted set, because picking one
silently (the RFC 6750 scheme versus a framework's single-word scheme) is a
policy decision that belongs to the app, not to this helper. Omitting it, or
passing an empty array, a non-string entry, or a value that is neither a
string nor an array of strings, raises - those are caller bugs, not attacker
input.

| `kind` | Meaning |
|--------|---------|
| `"missing"` | The header is absent (`nil`) or the empty string |
| `"scheme"` | A header was present, but its scheme word is not in the accepted set, or no token followed it |
| `"malformed"` | A decode-side check failed: token shape, base64, JSON, `alg` not HS256, or a non-numeric `exp` |
| `"sig"` | The signature does not match |
| `"exp"` | The token's `exp` is strictly before the current time |

On success it returns the claims table and `nil`. A non-string, non-nil
header or a bad secret raises - those are caller bugs, not attacker input.
What the helper deliberately does **not** do: pick an error message, choose
a response status, or fall back to an anonymous identity. That is policy,
and policy stays in the app.

## Key handling

HS256 is RFC 7518: the HMAC-SHA-256 key is the **raw secret octets** - exactly
the bytes a standard JWT library signs with and verifies against. This module
produces and accepts precisely those tags, for a secret of any length.

libsodium's `crypto_auth_hmacsha256` fixes the HMAC key at exactly 32 bytes, and
`lunet.sodium` deliberately refuses any other length rather than silently pad or
truncate - so the module composes HMAC-SHA-256 in Lua on `lunet.sodium.sha256`
(still libsodium's hash, through the FFI), following RFC 2104:

- a **key longer than the 64-byte block is hashed first** - the standard's own
  reduction, so long keys produce exactly the tags plain HMAC-SHA-256 produces;
- **every other key is used as-is**, zero-padded to the block exactly as HMAC
  itself pads - which is why a short secret (`"Jefe"`, `"secret"`, twenty `0x0b`
  bytes) verifies the tags a standard library issues.

The result is bit-identical to plain HMAC-SHA-256 for EVERY key length - no
subkey derivation, no re-hashing of short secrets. Sign and verify share one
key-handling helper, so the policy is invisible to callers as long as the same
secret goes in on both sides.

## exp policy

- A token **without** an `exp` claim never expires - `decode` succeeds.
- An `exp` claim must be a number; anything else is `malformed`.
- A token is expired once `exp` is **strictly before** the current time.
- Issue expiries with `opts.expires_in`, or set `payload.exp` yourself.

## Example: issue a token on login, verify per request

```lua
local security = require("lunet.security")
local jwt = security.jwt

local SECRET = os.getenv("JWT_SECRET")  -- keep it out of the source tree

-- On login (after checking the credentials):
local token = jwt.encode({ sub = user.id, name = user.name },
                         SECRET, { expires_in = 3600 })

-- On every authenticated request: hand the header value straight
-- over (nil when the framework has no header - "missing" comes back).
local function auth_user(header)
  local claims, kind = jwt.bearer(header, SECRET)
  if not claims then
    return nil, kind  -- missing / scheme / malformed / sig / exp
  end
  return claims
end
```

## Packaging

`lunet/security.lua` ships in every release archive beside `sqlite3.lua` - 
a Lua module with no binary of its own; its crypto is libsodium's, linked
via `liblunet_crypto`. `lunet/sodium.lua`, `lunet/paxe.lua` and
`lunet/jsonic.lua` (the dependencies) ship alongside it; see
[docs/RELEASE-LAYOUT.md](RELEASE-LAYOUT.md).

## Tests

`spec/security_spec.lua` covers: independent-implementation HMAC known-answer
vectors over the raw secret (RFC 4231 test cases 1 and 2 verbatim through the
raw path, cases 5 and 7 through the standard hash-the-key path, and an
externally computed short-secret signature for a fixed JWT signing input), the
negative pin that subkey-derived tags do not verify, per-byte tamper rejection, base64url RFC 4648 vectors and binary round-trips, JWT
encode/decode round-trips (including a standard-library token with a short raw
secret), the `exp` policy, the alg-confusion defence, and every named error
string. The suite pends cleanly when `liblunet_crypto` (or jsonic's native
decoder) has not been built.

## References

- RFC 2104 - HMAC: Keyed-Hashing for Message Authentication
- RFC 4231 - Test Cases for HMAC-SHA-256
- RFC 4648 - The Base16, Base32, and Base64 Data Encodings (the URL-safe
  profile)
- RFC 7518 - JSON Web Algorithms (HS256: HMAC with SHA-256 over the raw secret
  octets)
- RFC 7515/7519 - JSON Web Signature / JSON Web Token
- [docs/SODIUM.md](SODIUM.md) - the underlying primitives and their security
  boundary (the HMAC key crosses the FFI as ordinary Lua string data)
