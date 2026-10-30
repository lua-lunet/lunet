# ext/paxe — AGENTS

`ext/paxe` is the **UDP transport** of the PAXE protocol. It is a wrapper around
https://github.com/lua-lunet/paxe-core and exists solely to carry the UDP
message exchange defined by that protocol.

## Scope rule (hard)

This directory contains **only** the UDP protocol logic: the cdylib build
(`Cargo.toml`, `src/`, `paxe-core` vendored tree), the Lua loader
(`paxe.lua`), and the docs that describe the UDP transport.

It does NOT own, and must never absorb, the generic libsodium crypto surface
(SHA-256, HMAC-SHA-256, randombytes, base64, Argon2id password hashing, …).
Those primitives live under `ext/crypto` and are shared by every consumer, not
just the PAXE datagram path. Do not add crypto primitives here, and do not
re-introduce `sodium.lua` into this directory.

## References

- Protocol core: https://github.com/lua-lunet/paxe-core
- This directory's upstream mirror: https://github.com/lua-lunet/lunet/tree/main/ext/paxe
- Crypto surface: `ext/crypto/` (moved out of here)
