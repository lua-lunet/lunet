# PAXE: Packet Encryption Extension Module

PAXE (Packet Encryption) is lunet's datagram encryption extension: authenticated, encrypted peer-to-peer UDP traffic for clusters, driven from Lua. It protects one UDP payload at a time — no handshake, no session, no ordering or replay guarantees.

The protocol core is **[paxe-core](https://github.com/lua-lunet/paxe-core)**, a zero-dependency sans-io Rust crate consumed as a pinned git dependency (`tag = "v0.1.0"` in `ext/paxe/Cargo.toml`; the exact commit is recorded in `ext/paxe/Cargo.lock`). The lunet-side crate `ext/paxe` owns the C ABI and builds the `liblunet_paxe` cdylib, which `require("lunet.paxe")` loads through the LuaJIT FFI via the loader `ext/paxe/paxe.lua` — the same loading model as `lunet.jsonic`. The extension is pure opt-in: it is never linked into `lunet-run`.

The **normative wire-format and security contract** is paxe-core's [PAXE.md](https://github.com/lua-lunet/paxe-core/blob/v0.1.0/PAXE.md). This document is the lunet integration reference: it describes what the Lua API does, and restates only the parts of the wire contract a lunet operator touches. Where this document and the upstream contract disagree, the upstream document wins — please report the drift.

## Overview

- **AES-256-GCM** authenticated encryption for every frame, via libsodium (statically linked into the cdylib)
- **One 32-byte pre-shared key per link** (per unordered node pair), injected out of band; no on-wire key negotiation, no SRP, no certificates
- Keys addressed by **(peer node id, epoch)** — a 5-bit epoch (0–31) riding in the authenticated flags byte makes rotation a procedure, not a flag day
- **Standard frames only, on send**: `paxe.seal` always produces a standard one-recipient frame, at every payload size — there is no size-based mode selection
- **Reusable-DEK fanout frames on receive**: `paxe.open` transparently opens a reusable-DEK frame sealed by a Rust fanout host (the C ABI exposes no fanout sealer)
- **Per-socket UDP protection** via `paxe.protect()`; there is deliberately no process-global enable switch
- Drop-with-policy failure semantics: rejections never surface a reason to the caller (no decryption oracle); cumulative statistics counters are the diagnostic channel

## Building

Prerequisites: a Rust toolchain (rustup; the pinned channel in `ext/paxe/rust-toolchain.toml` is installed automatically on first use), a C compiler for libsodium's build glue, and a **static libsodium** (`libsodium.a` / `libsodium.lib`). paxe-core's build script locates the archive via `PAXE_SODIUM_LIB_DIR`, then `pkg-config --libs --static libsodium`, then the vcpkg static-triplet path on Windows; it hard-fails rather than fall back to a shared library. Debian/Ubuntu `libsodium-dev` and Homebrew `libsodium` both ship the archive.

```bash
xmake build-paxe     # cargo build --release in ext/paxe
xmake test-paxe      # the crate's FFI boundary test suite (debug + release)
```

`paxe-core` is a **private** repository. Cargo fetches it over SSH (`git = "ssh://git@github.com/...` in `ext/paxe/Cargo.toml`) using your ordinary GitHub SSH keys, via the git CLI (`ext/paxe/.cargo/config.toml` sets `net.git-fetch-with-cli`); CI rewrites the URL to a token-authenticated HTTPS one. A machine without GitHub SSH access cannot build the extension.

### Build artifacts

- `ext/paxe/target/release/liblunet_paxe.so` (Linux), `.dylib` (macOS), `lunet_paxe.dll` (Windows)
- The loader is `ext/paxe/paxe.lua`; `LUNET_PAXE_LIB` overrides the library path it loads
- Release archives ship both as `lunet/paxe.lua` + the cdylib beside it, self-contained (libsodium is linked statically)

## Wire format, as seen from lunet

All multi-byte integer fields are big-endian. Every frame starts with a 9-byte prefix:

| Bytes | Field | Meaning |
|-------|-------|---------|
| 0–1 | `fromId` | Source node identifier (u16) |
| 2–3 | `toId` | Destination node identifier (u16) |
| 4–5 | `channel` | Channel identifier (u16) |
| 6–7 | `length` | **Plaintext** payload length in bytes |
| 8 | flags | bit 0: 0 = standard, 1 = reusable-DEK; bit 1: must be 0; bit 2: must be 1; bits 3–7: key epoch (0–31) |

The flags byte is **inside the authenticated span**: the AES-GCM AAD of a standard frame is the exact 9-byte prefix, so addressing, mode and epoch cannot be altered without failing authentication. A receiver rejects any frame with bit 1 set or bit 2 clear — the cheap garbage filter.

### Standard frame (what `paxe.seal` produces)

```
Prefix(9) ‖ Nonce(12) ‖ Ciphertext(N) ‖ Tag(16)
```

Overhead **37 bytes**; the largest standard plaintext in a 65507-byte UDP datagram is **65470 bytes**. Sealed directly under the recipient link key with a fresh CSPRNG nonce per frame.

### Reusable-DEK fanout frame (what `paxe.open` may receive)

A Rust fanout host protects one payload once and emits one complete datagram per recipient; the body bytes are identical in every recipient's datagram, only the prefix and the DEK envelope differ:

```
Prefix(9) ‖ EnvelopeNonce(12) ‖ EncryptedDEK(32) ‖ EnvelopeTag(16) ‖ BodyNonce(12) ‖ BodyCiphertext(N) ‖ BodyTag(16)
```

Overhead **97 bytes**; the largest reusable-DEK plaintext is **65410 bytes**. The body is encrypted once under a fresh 32-byte DEK; each recipient's envelope is the DEK sealed under that recipient's link key, with the envelope AAD binding the recipient prefix to the exact body nonce and tag. Both GCM tags must verify before any plaintext is released. There is no unauthenticated key wrap and no redundant inner length field.

### Mode on the wire

`paxe.seal` always seals **standard** — payload size never selects a mode, and there is no API for forcing one. `paxe.open` chooses the parser only from the validated mode flag and reports the mode it opened (`"standard"` or `"dek"`). Receivers never infer a mode from payload or datagram size.

## Key management

### One key per link

Keys are 32-byte shared secrets — one per unordered node pair — injected out of band by an operator (provisioned over ssh, from a secret manager, from configuration). Per-link granularity is the load-bearing security property: `fromId` is authenticated, but authentication binds `fromId` only to *whoever holds the key*. Under a cluster-wide key any node could seal a frame claiming any `fromId`; with one key per pair, a third node cannot forge `fromId=A` addressed to `toId=B`, because it does not hold the A↔B key.

A receiver locates the key by **(peer node id, epoch)**: the peer is the header `fromId`, the epoch is flags bits 3–7, and the local id is configured once via `paxe.set_local_id`.

### Rotation

`paxe.seal` takes no epoch parameter: the send epoch is always the **newest epoch installed for the peer**, so installing a new epoch switches senders at once. Rotation is a three-step procedure with old and new keys coexisting throughout:

1. Install the new key under a new epoch on both peers; the old epoch remains installed.
2. Senders switch the moment the new epoch is installed.
3. Retire the old epoch once no sender is using it (`paxe.keystore_retire`).

A rolling restart rotates the whole cluster with no flag day and no dropped traffic.

### Key storage

Installed keys live in guarded, `mlock`ed, zeroed-on-drop libsodium allocations owned by the Rust library; key material never crosses the FFI outward. `paxe.init` registers an `atexit` hook that erases the keystore at normal process exit even when a script never calls `paxe.shutdown()`. See [Security Considerations](#security-considerations) for the crash-path platform split.

## Limits

The largest possible UDP datagram is 65507 bytes. Maximum plaintext payload follows from the per-frame overhead:

| Mode | Overhead | Maximum payload | Reachable via |
|------|----------|-----------------|---------------|
| Standard | 37 | **65470** | `paxe.seal` |
| Reusable-DEK | 97 | **65410** | receive-only from a Rust fanout host (`paxe.open`) |

A seal with an oversized payload fails with an operational error naming the standard maximum (`nil, message`) and moves `tx_oversize`. The length field is never truncated to make a frame fit: a truncated length produces a frame the peer is guaranteed to reject, with no error surfaced to the caller.

## Failure handling

A receiver that cannot parse, authenticate or decrypt a frame **drops it**. The rejection reason is deliberately not returned to the caller and never signalled to the sender: a receiver that explains *why* a forgery failed is a decryption oracle. `paxe.open` collapses every frame-level failure — too short, flags violation, length disagreement, unknown peer, unknown epoch, authentication failure, even an unconfigured keystore — to one result: `nil, "lunet.paxe: frame rejected"`.

Drops are governed by a process-wide failure policy, selected with `paxe.set_fail_policy`:

| Policy | Behaviour |
|--------|-----------|
| `silent` (default) | Discard; count only |
| `log_once` | Log the first drop of each reason per window to stderr (one `[PAXE]` line), then count silently |
| `verbose` | Log every drop |

Because the reason never reaches the caller, the **statistics counters are the only diagnostic channel**. They are process-global cumulative `u64` values that never reset while the process lives — not even on `shutdown()`. Measure **deltas** between two `paxe.stats()` snapshots, never absolute values:

| Counter | Meaning |
|---------|---------|
| `rx_total` | Frames presented to a configured receiver (opened + dropped) |
| `rx_ok` | Frames successfully opened |
| `rx_plaintext` | Dropped: not a PAXE frame addressed to this node at all — under the 9-byte prefix, or a header `toId` that is not the local id. Caught by the explicit addressing check at the socket boundary, never by the flags byte |
| `rx_short` | Dropped: too short to parse (under the 9-byte prefix, or under the 97-byte reusable-DEK minimum with the DEK bit set) |
| `rx_bad_flags` | Dropped: flags constant-bit violation (bit 1 set or bit 2 clear) — the cheap garbage filter |
| `rx_len_mismatch` | Dropped: declared plaintext length inconsistent with the actual frame size (the single length-consistency counter, for both modes) |
| `rx_no_peer` | Dropped: no key for the frame's `fromId` under ANY epoch — a **topology** problem (the link was never provisioned) |
| `rx_no_epoch` | Dropped: the `fromId` IS provisioned but not under the frame's epoch — a **rotation** problem |
| `rx_auth_fail` | Dropped: an AES-GCM tag did not verify (wrong key, tampered ciphertext or AAD, tampered DEK envelope or body) |
| `tx_total` | Frames successfully sealed |
| `tx_standard` | Of `tx_total`, sealed standard — always all of them through this API |
| `tx_dek` | Reusable-DEK fanout frames recorded by a Rust host (never advanced by this API) |
| `tx_oversize` | Seals rejected for an oversized payload |

**The invariant:** `rx_total == rx_ok + sum(all reject reasons)`. Every frame presented to a configured receiver lands in exactly one bucket. (Two paths are deliberately outside the accounting: a frame presented to an *unconfigured* receiver — the module is not running PAXE at all — and impossible internal results, which are not wire conditions.)

Two recorded policy decisions:

- **Log-once reset scope.** The log-once memo resets on `shutdown()` and whenever the policy is set to `log_once` — re-entering the policy is the operator's "tell me again, once" knob. An attacker cannot reset the memo, so within a window each reason logs at most once regardless of volume; that memoisation is the rate limiting.
- **No `fromId` or epoch in log lines.** Every field available at rejection time is attacker-controlled and *unverified* — that is why the frame is being dropped. Logging them would let an unauthenticated sender write arbitrary-looking peer identities into operator logs: a deception channel. Log lines carry the reason only, with a fixed `[PAXE] ` prefix so policy output is distinguishable from trace-build output on stderr.

## Channels

Channels 1–99 are reserved for system traffic; application channels start at 100, and channel 0 is permitted. The channel field is authenticated (inside the AAD) but not encrypted.

## Security Considerations

1. **Key size and storage**: keys are exactly 32 bytes and long-term shared secrets. Protect them at rest and inject them out of band.
2. **Nonce handling**: a fresh random 12-byte nonce per AES-GCM invocation (every frame, every fanout envelope), generated via libsodium. For a cluster-wide key, nonce accounting is cluster-wide: the birthday bound applies to the aggregate invocation count, and at ~2^32 invocations the 96-bit collision probability stays below 2^-32 — rotation policy must count the whole cluster, not an individual link.
3. **Authentication failure**: always a drop under the failure policy — never an error that explains the failure to a caller or sender (no decryption oracle).
4. **Header exposure**: the prefix is authenticated, not encrypted. `fromId`, `toId`, `channel`, `length` and the epoch are visible to a passive observer.
5. **No hardware path, no PAXE**: `paxe.init()` reports AES-256-GCM unavailability as an error rather than falling back to a software implementation. A libsodium build or CPU without the hardware path cannot run this extension — by design. (Platform note: the Debian trixie arm64 distro `libsodium` package is built without the ARM crypto-extension AES path, so `init()` reports unavailable even on capable hardware; the fix is a libsodium built with the ARM CE path — from source or Homebrew — not a lunet change. Linux CI builds libsodium 1.0.22 from source for this reason.)
6. **Core dumps (platform split)**: installed keys live in guarded, `mlock`ed libsodium allocations. `mlock` keeps the pages out of swap on every platform, but core-dump exclusion differs: on Linux, libsodium's `mlock` sets `MADV_DONTDUMP`; on macOS there is no such exclusion (Darwin has no `MADV_DONTDUMP`). `paxe.init()` therefore disables core dumps for the whole process by default (`setrlimit(RLIMIT_CORE, 0)`, soft limit only; the inherited hard limit is preserved). The rlimit is process-wide, which is sound because loading PAXE is itself the opt-in. **Re-enabling for debugging**: set `LUNET_PAXE_ALLOW_CORE_DUMPS=1` before launch (`ulimit -c unlimited`, `lldb -c /cores/...` work as usual); never set it on a production node — on macOS a crash then writes live key material into the core file. Defence in depth is also available at the OS level (`ulimit -c 0`).

## Lua API (`lunet.paxe`)

The module is the Rust cdylib `liblunet_paxe` loaded through the LuaJIT FFI by `ext/paxe/paxe.lua`; `LUNET_PAXE_LIB` overrides the library path. All cryptographic state — the keystore, i.e. all key material — lives inside the Rust library behind the FFI; Lua never holds keys except transiently when passing one in (see [Key material and the Lua VM](#key-material-and-the-lua-vm-known-limitation)).

### Functions

| Function | Returns | Meaning |
|----------|---------|---------|
| `paxe.version()` | string | paxe-core crate version (`"0.1.0"`). |
| `paxe.init()` | `true` \| `nil, message` | Initialise libsodium and require the AES-256-GCM hardware path. Idempotent. Reports `nil, message` when the host cannot provide it — PAXE refuses to operate rather than substitute another cipher. As its first act `init` also disables process core dumps (see [Security Considerations](#security-considerations)). |
| `paxe.set_local_id(node_id)` | `true` | Configure this node's identity (0–65535) — ONCE. A second call without an intervening `shutdown()` raises: silently re-creating the keystore would erase installed keys. |
| `paxe.keystore_set(peer, epoch, key)` | `true` \| `nil, message` | Install the 32-byte key shared with `peer` (0–65535) under `epoch` (0–31). Overwriting an occupied slot erases the old key. |
| `paxe.keystore_retire(peer, epoch)` | `true` \| `false` \| `nil, message` | Erase one `(peer, epoch)` slot. `false` when the slot was already empty (informational, not an error). |
| `paxe.keystore_clear()` | `true` | Erase every installed key. |
| `paxe.seal(payload, to_id, channel)` | `frame` \| `nil, message` | Seal `payload` (string) for `to_id` on `channel` as a **standard** frame — always, at every payload size. `fromId` is the configured local id — never a parameter, so no caller can spoof a source. The send epoch is the newest epoch installed for `to_id` (see [Rotation](#rotation)). `channel` must fit 16 bits and must not be in the reserved system range 1–99 (channel 0 is permitted). |
| `paxe.open(frame)` | `payload, from_id, channel, mode` \| `nil, message` | Open one received frame — standard, or reusable-DEK from a Rust fanout host. On success: the payload, the authenticated `fromId`, the channel, and the mode (`"standard"` or `"dek"`). On ANY failure: `nil` plus ONE opaque message — see [Failure handling](#failure-handling). |
| `paxe.stats()` | table | Snapshot of the process-global cumulative counters (13 fields; see [Failure handling](#failure-handling)). Never reset; measure deltas between snapshots. |
| `paxe.set_fail_policy(name)` | `true` \| `false` | Select the drop logging policy: `"silent"` (the default), `"log_once"`, `"verbose"` — case-insensitive. `false` for any other spelling or a non-string argument. |
| `paxe.protect(udpsock, config)` | `true` | Opt ONE `lunet.udp` socket into protection: subsequent `udp.send` seals before transmission and `udp.recv` opens before delivery (see [UDP socket protection](#udp-socket-protection)). `config.peer` (required) is the node id this socket seals for; `config.channel` (optional, default `0`) is the seal channel. Raises on a non-handle socket, a malformed config, or when the module is not configured — arming an unconfigured socket would silently drop every datagram. |
| `paxe.unprotect(udpsock)` | `true` | Remove protection from a socket. Idempotent. |
| `paxe.is_protected(udpsock)` | `false` \| `true, peer, channel` | Query a socket's protection and its configured peer/channel. |
| `paxe.shutdown()` | — | Zero and free every key and forget the local identity. Idempotent; `set_local_id` may configure afresh afterwards. The statistics counters are NOT reset (they are cumulative for the process lifetime); the log-once memo is. Key erasure at normal process exit does NOT depend on this call: `init` registers an `atexit` hook that zeroes the keystore even when a script never calls `shutdown()`. |

There is no `key_id` anywhere: keys are addressed by `(peer node id, epoch)`. And there is deliberately no `set_enabled`/`is_enabled`: protection is per-socket via `paxe.protect` (see below), which genuinely controls behaviour.

### Error conventions

One convention, applied uniformly:

- **Malformed arguments raise** a Lua error — they are bugs in the calling script. Wrong Lua types are checked by the loader; out-of-range and constraint-violating values are checked in Rust, each with a message naming the constraint: node ids fit 16 bits (0–65535), epochs fit 5 bits (0–31), channels fit 16 bits and respect the reserved 1–99 range, keys are exactly 32 bytes.
- **Operational failures return `nil, message`** — conditions a script handles: not initialised or configured, AES-256-GCM unavailable, no key installed for the peer, payload over the standard-mode maximum, keystore at capacity, secure-memory failure.

No input can crash the process: the library is built `panic = "abort"`, so a Rust panic would kill the LuaJIT host. Every value crossing the FFI boundary is therefore validated (types in the loader, ranges and lengths in Rust), and every check returns instead of panicking.

### UDP socket protection

`paxe.protect(udpsock, config)` opts ONE socket into PAXE. This is the recorded per-socket decision: there is no process-global enable flag, because a single global cannot express a process serving both an encrypted cluster port and an unencrypted local port — and the deleted C module's global switch was a no-op that printed "enabled". With per-socket protection as the only mechanism, there is no precedence question to document. `paxe.unprotect` disarms a socket, `paxe.is_protected` queries it, and `udp.close` also removes the socket's protection entry (a freed handle's pointer may be reused by a later bind and must never inherit stale protection).

**The integration is Lua-side, not in `src/udp.c`.** The Rust core is already reachable from Lua through the FFI; `require("lunet.udp")` returns a plain Lua table of C functions, so `protect` intercepts `send`/`recv`/`close` on that shared table and routes only registered sockets through the crypto path — unprotected sockets pass straight through to the raw C functions. Wiring the C instead would have needed a new C ABI into Rust and would have run crypto in udp.c's receive callback, which executes on the libuv loop rather than a Lua coroutine — exactly the context the project's debugging notes document for use-after-free crashes. The C callback and `udp_ctx_t` are untouched and never see key material.

**Decryption happens at delivery time**, when Lua calls `udp.recv` — not at arrival time in the libuv callback. The C receive queue therefore holds ciphertext, never plaintext: no opened payload lingers in C memory between arrival and `recv`, and no key material is needed at queue-drain time. A queue flush at `udp.close` discards ciphertext that was never authenticated — uncounted, because it never reached the gate below — which is the same end state as a drop, for frames that were undeliverable anyway.

On receive, the order per datagram is:

1. **The explicit plaintext gate.** A datagram is treated as a PAXE frame only if it carries at least the 9-byte prefix AND its header `toId` equals the configured local id. Anything else — plaintext, foreign-protocol or misaddressed traffic — is dropped and counted as `rx_plaintext`, by the addressing check, NEVER by the flags constant-bit gate: crafted plaintext could have a byte 8 that passes that gate, and when the two coincide (ordinary garbage) `rx_plaintext`, not `rx_bad_flags`, is the counter that moves.
2. **Open.** A datagram addressed to this node goes to `open`. On success `udp.recv(sock)` returns `data, host, port, from_id, channel` — the plaintext, the transport-level sender address, and the AUTHENTICATED `fromId` and channel. On ANY failure the failure policy applies, the reason counter moves, and NOTHING is delivered — no data, no error indicator; `recv` simply keeps waiting for the next datagram. A close or error while waiting passes through unchanged (`nil, nil, message`).

On send, `udp.send(sock, host, port, data [, peer [, channel]])` seals `data` before transmission: the peer from the call or the socket's configured peer, the channel likewise (default `0`), the send epoch the newest installed for the peer, always a standard frame. A seal failure — unconfigured, no key for the peer, or an oversized payload — fails the send with a clear error naming the cause; nothing is transmitted, and oversize moves `tx_oversize`.

Drop visibility: datagram arrival is traced by udp.c's `UDP_TRACE_RX` in trace builds; every drop is counted in Rust and reported through the failure policy (`[PAXE] drop: <reason>` lines under `log_once`/`verbose`) — the same mechanism a synchronous `open` uses, not a parallel one.

**Key erasure at process exit is owned by the runtime**: `paxe.init` registers an `atexit` hook that zeroes and frees the keystore at normal termination even when a script never calls `shutdown()`. No hook can run on `abort()`/`SIGKILL`; the mitigation THERE is platform-split ([Security Considerations](#security-considerations) item 6): on Linux the guarded pages' `MADV_DONTDUMP` keeps them out of the kernel core; on macOS, where no such exclusion exists, the mitigation is `init`'s default core-dump suppression — no core is written at all.

### Constants

`paxe.OVERHEAD_STANDARD` (37), `paxe.OVERHEAD_DEK` (97), `paxe.MAX_PAYLOAD_STANDARD` (65470) and `paxe.MAX_PAYLOAD_DEK` (65410) are read from the Rust library at load time — computed by the same layers that build the frames, never restated as literals in Lua. The DEK pair describes reusable-DEK fanout frames this host may *receive*; the C ABI seals standard frames only. (The deleted C implementation hard-coded 36 and 82 in a `#define` and in the docs, and both were wrong in the same way. One source of truth, exported.)

### Key material and the Lua VM (known limitation)

Keys reach the module as Lua strings, and a Lua string lives inside the Lua VM: interned, garbage-collected, immutable and freely copied by the VM, in unguarded, swappable memory that the module cannot erase. Passing a 32-byte key to `keystore_set` therefore exposes that copy for as long as the VM happens to retain it. The module's guarded, mlocked, zeroed-on-drop storage protects only the copy Rust keeps — it cannot protect the copy Lua holds. This is a real limitation, stated honestly rather than glossed.

**Recorded decision:** the Lua string is the only key-loading path in this release. A Rust-side file loader — reading a provisioned key file straight into guarded memory so the bytes never transit the VM — is a candidate follow-up and is deliberately not included here. Operators who cannot accept VM transit must treat the process image and swap as key-material-bearing until it lands, exactly as they already must for any secret configured through Lua.

## Examples and tests

- `examples/06_paxe_encryption.lua` — the guided API walkthrough (init through protected UDP sockets)
- `examples/07_paxe_stress.lua` — stress test: byte-exact assertions on every op plus full counter reconciliation
- `spec/paxe_spec.lua` — the behavioural suite for the Lua boundary (runs under `xmake test`; pending when the cdylib is not built)
- `test/smoke_paxe.lua` — standalone smoke (`lunet-run test/smoke_paxe.lua`)
- `test/run_paxe_udp_e2e.sh` — two-process protected-UDP end-to-end over loopback
- The wire format itself (known-answer vectors, tamper matrices, both frame geometries) is pinned by paxe-core's own `cargo test` suite, which runs in that repository — lunet pins the released tag, so the format cannot change under a lunet release without a reviewed edit to `ext/paxe/Cargo.toml`

## References

- paxe-core (protocol core and normative wire contract): https://github.com/lua-lunet/paxe-core ([PAXE.md](https://github.com/lua-lunet/paxe-core/blob/v0.1.0/PAXE.md))
- libsodium: https://doc.libsodium.org/
- AES-256-GCM: https://en.wikipedia.org/wiki/Galois/Counter_Mode
- Lunet architecture: See README.md and AGENTS.md
