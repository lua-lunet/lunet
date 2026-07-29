# PAXE: Packet Encryption Extension Module

PAXE (Packet Encryption) is a secure datagram encryption extension for Lunet, designed for clusters that need authenticated, encrypted peer-to-peer UDP traffic at the application level.

This document is the authoritative specification of the PAXE wire protocol. Implementations are written against this document; where it and any older description disagree, this document wins. PAXE follows the wire format of the reference implementation ([trex-paxe](https://github.com/trex-paxos/trex-paxos-jvm/blob/main/trex-paxe/README.md)) except where a divergence is explicitly documented below.

## Status

The wire format, key model, limits and failure semantics below ARE the implemented contract: the cryptographic core (header/flags codec, secure keystore, standard and DEK seal/open, automatic mode selection) and the Lua-facing API (`lunet.paxe`, see [Lua API](#lua-api-lunetpaxe)) are implemented and tested.

**PAXE does not yet protect socket traffic**: nothing is wired between the module and lunet's UDP sockets. That integration lands separately, and with it `set_enabled`/`is_enabled` — which deliberately do not exist until they genuinely control behaviour. (An earlier implementation exposed `set_enabled` as a no-op while an example printed "PAXE enabled"; that defect is not being repeated.) The statistics counters and the failure policies of [Failure Handling](#failure-handling) are implemented (`paxe.stats()`, `paxe.set_fail_policy()`).

## Overview

PAXE is an **extension module** that:

- Uses **libsodium** for all cryptographic operations
- Encrypts payloads with **AES-256-GCM** (authenticated encryption)
- Supports two frame modes — **standard** and **DEK** (Data Encryption Key) — selected automatically by payload size
- Authenticates the header and flags of every frame as additional authenticated data (AAD)
- Uses **one 32-byte shared key per link** (per unordered node pair), injected out of band
- Locates keys by **peer node identity plus a 5-bit key epoch** carried in the flags byte

## Wire Format

All multi-byte integer fields are **big-endian**. A frame is a single UDP datagram.

### Header (8 bytes)

Every frame begins with an 8-byte header:

| Bytes | Field | Size | Meaning |
|-------|-------|------|---------|
| 0–1 | `fromId` | 2 | Source node identifier |
| 2–3 | `toId` | 2 | Destination node identifier |
| 4–5 | `channel` | 2 | Channel identifier (multiplexing) |
| 6–7 | `length` | 2 | **Plaintext payload length** in bytes |

`length` is the length of the **plaintext payload**, not the length of the frame on the wire. The frame is longer than `length` by the mode's per-frame overhead (37 or 83 bytes).

### Flags (1 byte, offset 8)

| Bits | Value | Meaning |
|------|-------|---------|
| 0 | 0 or 1 | DEK flag: 0 = standard frame, 1 = DEK frame |
| 1 | must be 0 | Fixed pattern bit |
| 2 | must be 1 | Fixed pattern bit |
| 3–7 | 0–31 | 5-bit key epoch |

A receiver MUST reject any frame in which bit 1 is set or bit 2 is clear. This fixed pattern exists so that all-zero and all-ones garbage is rejected by inspecting a single byte — cheaply, before any cryptographic work, on a receive path that accepts unsolicited datagrams from anyone.

The epoch selects which key decrypts the frame; see [Key Management](#key-management). Because the epoch rides inside the authenticated span (see [Associated Data](#associated-data-aad)), it cannot be altered without failing authentication.

### Standard Frame

Used when the DEK flag is 0 (payloads below 64 bytes):

```
Header(8) ‖ Flags(1) ‖ Nonce(12) ‖ Ciphertext(N) ‖ Tag(16)
```

| Bytes | Field | Size |
|-------|-------|------|
| 0–7 | Header | 8 |
| 8 | Flags | 1 |
| 9–20 | Nonce | 12 |
| 21–20+N | Ciphertext | N |
| 21+N – end of frame | Tag | 16 |

Total frame size: **N + 37**. Per-frame overhead: **37 bytes**.

### DEK Frame

Used when the DEK flag is 1 (payloads of 64 bytes and above):

```
Header(8) ‖ Flags(1) ‖ KEK Nonce(12) ‖ Wrapped DEK(32) ‖ DEK Nonce(12) ‖ Length(2) ‖ Ciphertext(N) ‖ Tag(16)
```

| Bytes | Field | Size |
|-------|-------|------|
| 0–7 | Header | 8 |
| 8 | Flags | 1 |
| 9–20 | KEK Nonce | 12 |
| 21–52 | Wrapped DEK | 32 |
| 53–64 | DEK Nonce | 12 |
| 65–66 | Length | 2 |
| 67–66+N | Ciphertext | N |
| 67+N – end of frame | Tag | 16 |

Total frame size: **N + 83**. Per-frame overhead: **83 bytes**.

The inner `Length` field at bytes 65–66 duplicates the header `length` (the plaintext payload length). A receiver MUST reject a frame in which the two disagree. The duplication is redundant — the header length is already authenticated — and is retained only for compatibility with the reference implementation.

### Associated Data (AAD)

The AES-GCM additional authenticated data is **9 bytes: the header followed by the flags byte** (bytes 0–8 of the frame).

**Intentional divergence from the reference.** The reference places the flags byte outside the authenticated span. But bit 0 of the flags selects the parse geometry — the 37-byte versus the 83-byte layout — so an unauthenticated flags byte would let an attacker flip how a receiver interprets a frame: a mode-confusion vector. PAXE therefore authenticates the flags byte. The same span authenticates the key epoch, which is what makes epoch-based rotation safe.

## Mode Selection

The sender selects the frame mode by payload size:

| Payload size | Mode |
|--------------|------|
| Below 64 bytes | Standard |
| 64 bytes and above | DEK |

64 bytes is one CPU cache line. The threshold is fixed by the protocol — not a tuning knob — so that sender and receiver always agree on the layout.

## Cryptography

- **Payload**: AES-256-GCM with a fresh random 12-byte nonce per frame (generated via libsodium) and a 16-byte authentication tag. The AAD is the 9-byte header-plus-flags span described above.
- **DEK wrap** (DEK mode only): the per-frame 32-byte data encryption key is wrapped by XOR with a ChaCha20 stream keyed by the link key acting as KEK, using the KEK nonce. A stream XOR has no authentication tag, so **the wrap is unauthenticated by construction**. A corrupted wrapped DEK does not produce a wrap error; it produces a wrong DEK, and the frame fails later at the payload tag check. Corruption therefore surfaces as a payload tag failure, not a wrap failure. This is deliberate, and a reviewer should not read it as a missing check.

## Key Management

### One Key Per Link

Keys are 32-byte shared symmetric keys — **one per link, meaning per unordered node pair** — injected out of band by an operator (for example, provisioned over ssh). There is no on-wire key negotiation.

Per-link granularity is the load-bearing security property of the design. `fromId` is authenticated (it sits inside the AAD), but authentication only binds `fromId` to *whoever holds the key*. Under a single cluster-wide key, every node holds the same key, so any node could seal a frame claiming any `fromId` — the AAD would prevent nothing. With one key per unordered pair, a third node cannot forge a frame claiming `fromId=A` addressed to `toId=B`, because it does not hold the A↔B key. Per-link keys are what make a forged `fromId` impossible rather than merely unauthenticated.

**SRP v6a is deliberately not implemented.** The reference establishes its per-pair session keys with SRP (RFC 5054) handshakes plus HKDF; that machinery existed to avoid certificates. For a cluster whose operator can inject shared keys out of band it is not worth carrying, and its absence here is a decision, not an omission.

### Key Location

A receiver locates the decryption key by **(peer node id, epoch)**: the peer is the `fromId` in the header, the epoch is flags bits 3–7, and the local node's own id is configured once at initialisation.

### Rotation

Dropping SRP removed the reference's implicit rotation mechanism — there, sessions were re-established, so keys turned over naturally. Injected shared keys have no such property, which is why the 5-bit epoch exists: 32 epochs (0–31), making rotation a procedure rather than an event:

1. Install the new key under a new epoch on both peers; the old epoch remains installed.
2. Switch senders over to the new epoch.
3. Retire the old epoch once no sender is using it.

Old and new keys coexist throughout, so a rolling restart rotates the whole cluster with no flag day and no dropped traffic. The epoch costs nothing on the wire: bits 3–7 are reserved and unused in the reference, and PAXE puts them to work.

## Limits

The largest possible UDP datagram is 65507 bytes. The maximum plaintext payload follows from the per-frame overhead:

| Mode | Overhead | Maximum payload |
|------|----------|-----------------|
| Standard | 37 | 65507 − 37 = **65470 bytes** |
| DEK | 83 | 65507 − 83 = **65424 bytes** |

A sender MUST reject an oversized payload with an error. It must never truncate the length field to make a frame fit: a truncated length produces a frame the peer is guaranteed to reject, with no error surfaced to the caller. An earlier implementation did exactly that, and it is a debugging trap — do not reintroduce it.

## Failure Handling

A receiver that cannot parse, authenticate or decrypt a frame **drops it**. The rejection reason is deliberately not returned to the caller and never signalled to the sender: a receiver that explains *why* a forgery failed is a decryption oracle.

Drops are governed by a global failure policy, selected with `paxe.set_fail_policy`:

| Policy | Behaviour |
|--------|-----------|
| `silent` (default) | Discard; count only |
| `log_once` | Log the first drop of each kind per window to stderr (one `[PAXE]` line), then count silently |
| `verbose` | Log every drop |

Because the rejection reason never reaches the caller, the **statistics counters are the only diagnostic channel**. They are process-global, cumulative `u64` values that never reset while the process lives — measure deltas between two snapshots (`paxe.stats()`), never absolute values:

| Counter | Meaning |
|---------|---------|
| `rx_total` | Frames presented to a configured receiver (opened + dropped) |
| `rx_ok` | Frames successfully opened |
| `rx_short` | Dropped: too short to parse (under the 9-byte prefix, or under the 83-byte DEK minimum with the DEK bit set) |
| `rx_bad_flags` | Dropped: flags constant-bit violation (bit 1 set or bit 2 clear) — the cheap garbage filter |
| `rx_len_mismatch` | Dropped: declared plaintext length inconsistent with the actual frame size |
| `rx_no_peer` | Dropped: no key for the frame's `fromId` under ANY epoch — a **topology** problem (the link was never provisioned) |
| `rx_no_epoch` | Dropped: the `fromId` IS provisioned but not under the frame's epoch — a **rotation** problem (the two ends disagree about which epoch is live) |
| `rx_dek_len_mismatch` | Dropped: the DEK frame's redundant inner Length field disagrees with the header length |
| `rx_auth_fail` | Dropped: the AES-GCM tag did not verify (wrong key, tampered ciphertext or AAD, or a wrong DEK from a corrupted wrapped DEK) |
| `tx_total` | Frames successfully sealed |
| `tx_standard` | Of `tx_total`, sealed standard (below the 64-byte threshold) |
| `tx_dek` | Of `tx_total`, sealed DEK (at and above the threshold) — with automatic selection, this split is how an operator sees where the bandwidth/overhead balance falls |
| `tx_oversize` | Seals rejected for an oversized payload |

**The invariant:** `rx_total == rx_ok + sum(all reject reasons)`. Every frame presented to a configured receiver lands in exactly one of those buckets; a future reject reason added without a counter breaks this equation and is caught by it. (Two paths are deliberately outside the accounting: a frame presented to an *unconfigured* receiver — the module is not running PAXE at all — and impossible internal results, which are not wire conditions.) Unknown peer and unknown epoch are separate counters by design: the first means a configuration or topology problem, the second means a rotation went wrong, and collapsing them would throw away the distinction that makes the epoch mechanism debuggable.

There is deliberately **no counter for the ChaCha20 wrap**: a stream XOR does not authenticate and cannot fail — a corrupted wrapped DEK surfaces at the payload tag check and is counted in `rx_auth_fail`. (An earlier implementation error-checked the wrap and counted its "failure" as an authentication failure, tallying a condition that cannot occur.)

Two recorded policy decisions:

- **Log-once reset scope.** The log-once memory resets on `shutdown()` (a re-initialised module starts a fresh window) and whenever the policy is set to `log_once` — re-entering the policy is the operator's "tell me again, once" knob. An attacker cannot reset the memo (only the local operator can, through the API), so within a window each kind logs at most once regardless of volume; that memoisation is the rate limiting. The counters themselves never reset.
- **No `fromId` or epoch in rejection log lines.** Every field available at rejection time is attacker-controlled and *unverified* — that is why the frame is being dropped. Logging those fields would let an unauthenticated sender write arbitrary-looking peer identities into operator logs at the policy's rate: a deception channel, and under `verbose` a high-volume one. The counters carry the diagnostic signal without that exposure — a moved counter cannot lie about which counter moved. Log lines therefore carry the reason only, with a fixed `[PAXE] ` prefix so policy output is distinguishable from trace-build output on stderr (tests assert the prefix, never stderr emptiness, so they cannot invert between build modes).

**Intentional divergence from the reference**, which throws `SecurityException` on authentication failure: there is no caller to throw to for a datagram you are dropping anyway. Drop-with-policy is the correct semantics for UDP.

## Channels

Per the reference: channels 1–99 are reserved for system traffic, and application channels start at 100. The channel field is authenticated (it sits inside the AAD) but not encrypted.

## Intentional Divergences from the Reference

Each divergence below is documented with its reasoning in the section linked from the table:

| Aspect | Reference | PAXE (this document) | Reason |
|--------|-----------|----------------------|--------|
| Flags byte | Outside the authenticated span | Inside the AAD (9 bytes: header + flags) | Bit 0 selects the parse geometry; an unauthenticated flags byte is a mode-confusion vector |
| Flags bits 3–7 | Reserved | 5-bit key epoch (0–31) | Rotation without flag days, replacing the implicit turnover lost with SRP |
| Key establishment | SRP v6a (RFC 5054) + HKDF | Per-link shared keys injected out of band | Operator-provisioned cluster; session machinery not worth carrying |
| Authentication failure | `SecurityException` | Drop under a global policy | No caller to throw to for a dropped datagram |

## Security Considerations

1. **Key size and storage**: keys are exactly 32 bytes and long-term shared secrets. Protect them at rest and inject them out of band.
2. **Nonce handling**: a fresh random 12-byte nonce per frame, generated via libsodium.
3. **Authentication failure**: always a drop under the failure policy — never an error that explains the failure to a caller or sender (no decryption oracle).
4. **Header exposure**: the header and flags are authenticated, not encrypted. `fromId`, `toId`, `channel`, `length` and the epoch are visible to a passive observer.
5. **Wrapped DEK**: unauthenticated by construction; corruption surfaces at the payload tag check.

## Lua API (`lunet.paxe`)

The module is a Rust cdylib (`ext/paxe`) loaded through the LuaJIT FFI by the loader `ext/paxe/paxe.lua` — the same loading model as `lunet.jsonic`; the `LUNET_PAXE_LIB` environment variable overrides the library path. All cryptographic state — the keystore, i.e. all key material — lives inside the Rust library behind the FFI; Lua never holds keys except transiently when passing one in (see [Key material and the Lua VM](#key-material-and-the-lua-vm-known-limitation)).

### Functions

| Function | Returns | Meaning |
|----------|---------|---------|
| `paxe.version()` | string | Crate version. |
| `paxe.init()` | `true` \| `nil, message` | Initialise libsodium and require the AES-256-GCM hardware path. Idempotent. Reports `nil, message` when the host cannot provide it — PAXE refuses to operate rather than substitute another cipher. |
| `paxe.set_local_id(node_id)` | `true` | Configure this node's identity (0–65535) — ONCE. A second call without an intervening `shutdown()` raises: silently re-creating the keystore would erase installed keys. |
| `paxe.keystore_set(peer, epoch, key)` | `true` \| `nil, message` | Install the 32-byte key shared with `peer` (0–65535) under `epoch` (0–31). Overwriting an occupied slot erases the old key. |
| `paxe.keystore_retire(peer, epoch)` | `true` \| `false` \| `nil, message` | Erase one `(peer, epoch)` slot. `false` when the slot was already empty (informational, not an error). |
| `paxe.keystore_clear()` | `true` | Erase every installed key. |
| `paxe.seal(payload, to_id, channel)` | `frame` \| `nil, message` | Seal `payload` (string) for `to_id` on `channel`. `fromId` is the configured local id — never a parameter, so no caller can spoof a source. The mode is selected by payload size (standard below 64 bytes, DEK at and above). The send epoch is the newest epoch installed for `to_id` (see below). `channel` must fit 16 bits and must not be in the reserved system range 1–99 (application channels start at 100; channel 0 is permitted). |
| `paxe.open(frame)` | `payload, from_id, channel, mode` \| `nil, message` | Open one received frame. On success: the payload, the authenticated `fromId`, the channel, and the mode (`"standard"` or `"dek"`). On ANY failure: `nil` plus ONE opaque message — see [Opaque open failure](#opaque-open-failure). |
| `paxe.stats()` | table | Snapshot of the process-global cumulative counters (see [Failure Handling](#failure-handling)): `rx_total`, `rx_ok`, `rx_short`, `rx_bad_flags`, `rx_len_mismatch`, `rx_no_peer`, `rx_no_epoch`, `rx_dek_len_mismatch`, `rx_auth_fail`, `tx_total`, `tx_standard`, `tx_dek`, `tx_oversize`. Never reset; measure deltas between snapshots. |
| `paxe.set_fail_policy(name)` | `true` \| `false` | Select the drop logging policy: `"silent"` (the default), `"log_once"`, `"verbose"` — case-insensitive. `false` for any other spelling or a non-string argument. |
| `paxe.shutdown()` | — | Zero and free every key and forget the local identity. Idempotent; `set_local_id` may configure afresh afterwards. The statistics counters are NOT reset (they are cumulative for the process lifetime); the log-once memo is. |

There is no `key_id` anywhere: keys are addressed by `(peer node id, epoch)`. There is deliberately no `set_enabled`/`is_enabled` yet: they arrive with the socket integration, when they genuinely control transport protection. The statistics counters and the failure policy exist now and govern what the synchronous `open` reports; the UDP receive path will consult the same counters when the socket integration lands.

### Error conventions

One convention, applied uniformly:

- **Malformed arguments raise** a Lua error — they are bugs in the calling script. Wrong Lua types are checked by the loader; out-of-range and constraint-violating values are checked in Rust, each with a message naming the constraint: node ids fit 16 bits (0–65535), epochs fit 5 bits (0–31), channels fit 16 bits and respect the reserved 1–99 range, keys are exactly 32 bytes.
- **Operational failures return `nil, message`** — conditions a script handles: not initialised or configured, AES-256-GCM unavailable, no key installed for the peer, payload over the selected mode's maximum, keystore at capacity, secure-memory failure.

No input can crash the process: the library is built `panic = "abort"`, so a Rust panic would kill the LuaJIT host. Every value crossing the FFI boundary is therefore validated (types in the loader, ranges and lengths in Rust), and every check returns instead of panicking.

### The send epoch is the newest installed epoch

`seal` takes no epoch parameter. This makes [Rotation](#rotation) fully procedural: installing a key under a new epoch switches senders to it AT ONCE, because the newest (highest-numbered) epoch installed for a peer is always the send epoch. Frames carry it in flags bits 3–7; receivers locate keys by `(fromId, wire epoch)` and can open old- and new-epoch traffic throughout the rollover; retiring the old epoch then removes only it.

### Opaque open failure

`open` collapses EVERY frame-level failure — too short, flags constraint violation, length disagreement, unknown key or epoch, authentication failure, even an unconfigured keystore — to one result: `nil, "lunet.paxe: frame rejected"`. The rejection reason is never returned to the caller and never signalled to the sender: a receiver that explains why a forgery failed is a decryption oracle (see [Failure Handling](#failure-handling)). The typed reasons are recorded into the statistics counters at the reject points, before the collapse; they never cross the FFI.

### Constants

`paxe.OVERHEAD_STANDARD` (37), `paxe.OVERHEAD_DEK` (83), `paxe.MAX_PAYLOAD_STANDARD` (65470) and `paxe.MAX_PAYLOAD_DEK` (65424) are read from the Rust library at load time — computed by the same layers that build the frames, never restated as literals in Lua. (The deleted C hard-coded 36 and 82 in a `#define` and in the docs, and both were wrong in the same way. One source of truth, exported.)

### Key material and the Lua VM (known limitation)

Keys reach the module as Lua strings, and a Lua string lives inside the Lua VM: interned, garbage-collected, immutable and freely copied by the VM, in unguarded, swappable memory that the module cannot erase. Passing a 32-byte key to `keystore_set` therefore exposes that copy for as long as the VM happens to retain it. The module's guarded, mlocked, zeroed-on-drop storage protects only the copy Rust keeps — it cannot protect the copy Lua holds. This is a real limitation, stated honestly rather than glossed.

**Recorded decision:** the Lua string is the only key-loading path in this commit. A Rust-side file loader — reading a provisioned key file straight into guarded memory so the bytes never transit the VM — is a candidate follow-up and is deliberately not included here. Operators who cannot accept VM transit must treat the process image and swap as key-material-bearing until it lands, exactly as they already must for any secret configured through Lua.

## References

- Reference implementation (trex-paxe): https://github.com/trex-paxos/trex-paxos-jvm/blob/main/trex-paxe/README.md
- libsodium: https://doc.libsodium.org/
- AES-256-GCM: https://en.wikipedia.org/wiki/Galois/Counter_Mode
- ChaCha20 (libsodium): https://doc.libsodium.org/advanced/stream_ciphers/chacha20
- SRP (not implemented; see Key Management): RFC 5054, https://www.rfc-editor.org/rfc/rfc5054
- Lunet Architecture: See README.md and AGENTS.md
