# PAXE: Packet Encryption Extension Module

PAXE (Packet Encryption) is a secure datagram encryption extension for Lunet, designed for clusters that need authenticated, encrypted peer-to-peer UDP traffic at the application level.

This document is the authoritative specification of the PAXE wire protocol. Implementations are written against this document; where it and any older description disagree, this document wins. PAXE follows the wire format of the reference implementation ([trex-paxe](https://github.com/trex-paxos/trex-paxos-jvm/blob/main/trex-paxe/README.md)) except where a divergence is explicitly documented below.

## Status

As at the time of writing, **PAXE does not yet protect socket traffic**. The implementation is being written against this specification; the wire format, key model, limits and failure semantics below are the contract it will implement. The Lua-facing API, the build wiring and the examples land with that implementation, not before.

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

Drops are governed by a global failure policy:

| Policy | Behaviour |
|--------|-----------|
| `DROP` (silent) | Discard; count only |
| `LOG_ONCE` | Log the first drop of each kind, then count silently |
| `VERBOSE` | Log every drop |

The statistics counters are the intended diagnostic channel. They count total frames received and each rejection cause — too short, flags constraint violation, length disagreement, unknown key or epoch, authentication failure — so an operator can distinguish attack traffic from misconfiguration without opening an oracle.

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

## References

- Reference implementation (trex-paxe): https://github.com/trex-paxos/trex-paxos-jvm/blob/main/trex-paxe/README.md
- libsodium: https://doc.libsodium.org/
- AES-256-GCM: https://en.wikipedia.org/wiki/Galois/Counter_Mode
- ChaCha20 (libsodium): https://doc.libsodium.org/advanced/stream_ciphers/chacha20
- SRP (not implemented; see Key Management): RFC 5054, https://www.rfc-editor.org/rfc/rfc5054
- Lunet Architecture: See README.md and AGENTS.md
