# `lunet.paxe` — UDP transport of the PAXE protocol

`ext/paxe` is a wrapper around
[https://github.com/lua-lunet/paxe-core](https://github.com/lua-lunet/paxe-core).
The extension is **only** about the UDP transport of that protocol: sealing and
opening datagrams, per-socket UDP protection, and the counters that diagnose
drops. It is not a general crypto module.

The generic libsodium primitives that the PAXE cdylib happens to expose
(SHA-256, HMAC-SHA-256, randombytes, base64, and password hashing) are **not**
part of this transport and have been moved to `ext/crypto`. Do not grow this
directory into a shadow libsodium — see `docs/SODIUM.md` for the sanctioned
growth rule, which applies to `ext/crypto`, not here.

See `docs/PAXE.md` for the full Lua API and wire format.
