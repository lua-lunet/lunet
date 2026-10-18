# Sodium: Crypto Primitives Extension Module

`lunet.sodium` is a **minimal libsodium primitive surface**: one-shot SHA-256, one-shot HMAC-SHA-256 (the JWT HS256 primitive), `randombytes`, and base64 encode/decode (the encoding every JWT-shaped consumer needs). Five functions, nothing more.

It exists because the PAXE cdylib (`liblunet_paxe`) already **statically links libsodium** - every consumer of the binary archives carries the bytes for these ordinary primitives inside a library they already ship. Before this module those primitives were unreachable (the static sodium symbols are not exported from the cdylib), which forced scripts to load a **second** libsodium (Homebrew on macOS, a distro package on Linux) - two sodiums in one process, with `dlsym(RTLD_DEFAULT)` ambiguity. `lunet.sodium` reaches the primitives that are already there.

The module is loaded through the LuaJIT FFI from the **dylib handle** (`ffi.load` of the cdylib path), never through `ffi.C` / `RTLD_DEFAULT` - so a user-owned libsodium loaded into the same process can never capture the lookup. It is the same loading model as `lunet.paxe` and `lunet.jsonic`, and like them it is pure opt-in: nothing is linked into `lunet-run`.

## Overview

| Function | Purpose | libsodium primitive |
|----------|---------|---------------------|
| `sodium.sha256(data)` | checksums, content digests | `crypto_hash_sha256` |
| `sodium.hmac_sha256(data, key)` | JWT HS256 signing/verification, MACs | `crypto_auth_hmacsha256` |
| `sodium.random(n)` | unpredictable bytes (ids, salts, nonces) | `randombytes_buf` |
| `sodium.base64_encode(data, variant)` | JWT header/payload encoding, wire formats | `sodium_bin2base64` |
| `sodium.base64_decode(data, variant)` | JWT header/payload decoding, wire formats | `sodium_base642bin` |

Why these: SHA-256 and HMAC-SHA-256 cover checksums and JWT HS256 - the most common reason to reach for sodium from Lua. `randombytes_buf` is the natural companion, because nobody should mix two RNGs in one process; this draw uses the **same CSPRNG PAXE uses** for its nonces and DEKs. Base64 is the same receipt one layer up: every consumer of this module re-implements it in pure Lua for the JWT profile, per-request, on the hottest path in their app - the linked library already owns it, so the runtime exposes it and the copies die.

## Requirements and loading

Requires the PAXE cdylib: `xmake build-paxe` from a source checkout, or `lunet/liblunet_paxe.*` from a binary release archive (the loader `lunet/sodium.lua` sits beside it and finds it relative to its own directory). No PAXE configuration is needed - the primitives share only the cdylib with `lunet.paxe`, not its state: no `paxe.init()`, no `set_local_id()`, and the PAXE statistics counters are untouched.

| Environment variable | Effect |
|----------------------|--------|
| `LUNET_SODIUM_LIB` | Override the cdylib path this loader binds (checked first) |
| `LUNET_PAXE_LIB` | Same, shared with `ext/paxe/paxe.lua` (checked second) |

Unlike PAXE there is **no AES-256-GCM hardware requirement** - these are portable software primitives available on every platform, including Windows (where `lunet.lnt_shared` / `lunet.jsonic` are not shipped).

## Lua API (`lunet.sodium`)

Hash and random outputs are **raw binary strings** (32 bytes for the hash functions, `n` bytes for random). Base64 is provided by the module itself (`sodium_bin2base64` / `sodium_base642bin` from the linked library) - a reader that re-implements base64 per application is the exact pattern this surface exists to retire: the JWT consumer profile in every consumer library needs it, and a pure-Lua re-implementation pays for itself in per-request work that the linked library already owns. Hex formatting remains the caller's job.

```lua
local sodium = require("lunet.sodium")
```

### `sodium.BYTES`

Digest/tag size in bytes of `sha256` and `hmac_sha256` outputs: 32.

### `sodium.sha256(data) -> digest`

One-shot SHA-256 over `data` (a string, any bytes including NULs). Returns the 32-byte digest.

### `sodium.hmac_sha256(data, key) -> tag`

One-shot HMAC-SHA-256 over `data`. `key` must be **exactly 32 bytes** - libsodium's fixed HMAC-SHA-256 key size (`crypto_auth_hmacsha256_KEYBYTES`); a wrong length raises. Returns the 32-byte tag.

### `sodium.random(n) -> bytes`

Draws `n` unpredictable bytes from the system CSPRNG. `n` is a non-negative integer; 0 returns the empty string.

### `sodium.base64_encode(data, variant) -> b64`

Encodes `data` (a string, any bytes) with the linked library's `sodium_bin2base64` under a variant from the table below. The URL-safe, unpadded variant is the JWT profile. Returns the encoded string (padded or unpadded exactly as the variant defines).

### `sodium.base64_decode(data, variant) -> bytes`

Decodes `data` with the linked library's `sodium_base642bin` under the same variants, writing straight into the loader's own buffer - no transient allocation. The full string must parse: malformed input, or trailing characters after the payload, raise with a reject message since a caller passing them is a bug in the calling script; malformed input collapses to a single opaque reject because the library reports the error as a binary result, not as text.

| Constants on the module | Value | Meaning |
|---|---|---|
| `sodium.BASE64_VARIANT_ORIGINAL` | 1 | Standard alphabet, padded |
| `sodium.BASE64_VARIANT_ORIGINAL_NO_PADDING` | 3 | Standard alphabet, unpadded |
| `sodium.BASE64_VARIANT_URLSAFE` | 5 | URL-safe alphabet, padded |
| `sodium.BASE64_VARIANT_URLSAFE_NO_PADDING` | 7 | URL-safe alphabet, unpadded - the JWT profile |

The values are libsodium's own `sodium_base64_VARIANT_*` macro values, mirrored on the module - never restate them as bare integers in user code.

### Error convention

The same shape as `lunet.paxe`:

- **Malformed arguments raise** a Lua error naming the argument and the constraint - they are bugs in the calling script.
- **Operational failures** (libsodium could not be initialised - an environment property) return `nil, message`.

On any normal host the operational arm is unreachable: the functions initialise libsodium themselves (idempotent) and the primitives have no other failure mode.

### Example: checksum

```lua
local sodium = require("lunet.sodium")

local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

print(hex(sodium.sha256("abc")))
-- ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
```

### Example: JWT HS256 signing input

HS256 is HMAC-SHA-256 over the `header.payload` bytes with the base64url-decoded secret (RFC 8725 requires the decoded key to be at least 32 bytes - exactly this API's key size):

```lua
local sodium = require("lunet.sodium")

local signing_input = header_b64u .. "." .. payload_b64u
local sig = sodium.hmac_sha256(signing_input, secret_32bytes)
-- verify: a constant-time comparison of the received signature is the
-- caller's job; tag equality via == leaks nothing exploitable for
-- HMAC-SHA-256, but constant-time compare is the disciplined default.
```

## Standalone FFI (without lunet-run)

Any LuaJIT program can load the cdylib directly. The complete exported surface is five symbols (plus the shared `lunet_paxe_last_error` used for messages):

```lua
ffi.cdef[[
  int lunet_sodium_sha256(const uint8_t* input, size_t input_len, uint8_t* out);
  int lunet_sodium_hmac_sha256(const uint8_t* input, size_t input_len,
                               const uint8_t* key, size_t key_len, uint8_t* out);
  int lunet_sodium_randombytes(uint8_t* out, size_t out_len);
  int lunet_sodium_base64_encode(const uint8_t* input, size_t input_len,
                                 int variant, uint8_t* out, size_t out_cap);
  int lunet_sodium_base64_decode(const uint8_t* input, size_t input_len,
                                 int variant, uint8_t* out, size_t out_cap,
                                 size_t* written);
  const uint8_t* lunet_paxe_last_error(size_t* len);
]]
```

Return codes:

| Code | Meaning |
|------|---------|
| `0` | Success |
| `-2` | Malformed argument (null pointer where bytes are required, wrong key length, output buffer smaller than the documented requirement, unknown base64 variant) - message in `lunet_paxe_last_error` |
| `-1` | Operational failure (libsodium initialisation) - message in `lunet_paxe_last_error` |

Caller contract: `out` buffers must be valid for the documented write size - 32 bytes for the two hash outputs, `out_len` for random; for `base64_encode`, `((input_len) / 3) * 4 + 5` bytes (the maximum over all variants of the linked library's `sodium_base64_encoded_len(bin_len, variant)`, NUL included); for `base64_decode`, `((input_len + 3) / 4) * 3` bytes, with the actual number of decoded bytes returned through `written` (the decode result is binary, so length is how you read it - never a NUL sentinel). `lunet_sodium_randombytes` with a zero length is a successful no-op.

## ABI promise, and what is deliberately NOT promised

**Promised:** the five `lunet_sodium_*` symbols above, with these signatures and return codes, in every release that ships the PAXE cdylib.

**Not promised, deliberately:**

- **No wholesale export of the libsodium namespace.** The vendored sodium version must not become a public ABI promise, and a full export would be a symbol-collision hazard with user-loaded sodiums. If you need a primitive this surface lacks, load your own crypto library - this module will not grow one symbol at a time into a shadow libsodium.
- **No streaming/incremental variants.** One-shot hashing and HMAC cover the JWT use case; the streaming APIs (`crypto_hash_sha256_*_init/update/final`) are not exposed.
- **No keyring or guarded memory here.** `lunet.paxe` keeps that role; this surface never touches the PAXE keystore, identity, counters or failure policy.

Why base64 is here despite the rule above: it is not a shadow libsodium growth path - the linked library already ships it next to the siblings this surface exposes, every JWT-shaped consumer re-implements it, and a re-implementation per application is exactly the per-request duplication this surface exists to retire. If the surface ever grows again, it grows in the same direction: whole-primitive capability the library already provides, not one-attribute helpers.

## Security considerations

- **Stateless hashing crosses no secrets.** `sha256` input is whatever the script hashes; nothing is retained beyond the call.
- **HMAC key material does cross the FFI.** The 32-byte key is ordinary Lua string data: it transits the Lua VM unguarded, exactly like the key string passed to `paxe.keystore_set` (see the honest statement in `docs/PAXE.md`). Guarded, `mlock`ed, zeroed-on-drop key memory remains PAXE's job; this surface is for ordinary primitives, not key custody. Derive or load your JWT secrets accordingly.
- **One RNG per process.** `sodium.random` draws from the same CSPRNG PAXE uses, so a process using both never mixes two random sources.
- **The hash and random outputs are raw bytes.** Hex formatting and any length/policy shaping remain the caller's job; base64 is provided (two variants, library-native) because that is the one encoding every JWT-shaped consumer needs and re-implements.
- **Base64 crosses no secrets either.** It is a plain transform with no keying, no state and no hazard beyond the input's own sensitivity: bytes that are secret remain secret while encoded.

## Tests

- `spec/sodium_spec.lua` - the Lua behavioural suite (runs in `xmake test`): FIPS 180-4 SHA-256 known answers, independently computed HMAC-SHA-256 known answers, error conventions, random shape checks, base64 round-trips and the malformed-input conventions.
- `ext/paxe/src/lib.rs` (the `ffi_tests` sodium section) - the same exports driven at the C level, including the known-answer vectors and null/wrong-length argument handling.

## References

- [libsodium documentation - SHA-2](https://doc.libsodium.org/hashing/sha-2)
- [libsodium documentation - HMAC-SHA-2](https://doc.libsodium.org/advanced/hmac-sha2)
- [libsodium documentation - Generating random data](https://doc.libsodium.org/generating_random_data)
- [libsodium documentation - Base64](https://doc.libsodium.org/helpers/base64)
- [RFC 8725 - Best Current Practices for JWT](https://www.rfc-editor.org/rfc/rfc8725) (HS256 and key-size requirements)
- [`docs/PAXE.md`](PAXE.md) - the other surface of the same cdylib
