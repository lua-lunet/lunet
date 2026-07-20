# Attribution

This extension wraps [`jsonic`](https://github.com/g1mv/jsonic) by
[Guillaume Voirin (g1mv)](https://github.com/g1mv) — a small, fast,
dependency-free JSON parsing library for Rust.

- Upstream repository: <https://github.com/g1mv/jsonic>
- Upstream crate: <https://crates.io/crates/jsonic>
- Upstream license: dual MIT / Apache-2.0 (verbatim copies included in this
  directory as `LICENSE-MIT-jsonic` and `LICENSE-APACHE-jsonic`)

`jsonic` is consumed as an ordinary Cargo dependency (see `Cargo.toml`), not
vendored/modified source. `jsonic` only parses JSON; it does not serialise.

## What lunet adds on top

- `src/lib.rs` — parses `jsonic` and emits a flat tagged buffer so no
  borrowed/lifetime state crosses the FFI boundary.
- `src/unescape.rs` — JSON string unescaping (`\n`, `\uXXXX`, surrogate
  pairs, etc.), since `jsonic::JsonItem::as_str()` returns the raw source
  text with quotes stripped but escapes left undecoded (verified empirically
  in `src/lib.rs`'s `probe` test).
- `jsonic.lua` — dkjson 2.10 encode logic (MIT-licensed, exact upstream
  source lifted with attribution in `LICENSE-DKJSON`), plus a small
  wrapper around the Rust-backed decode path and tagged-buffer reader.

This directory's own code (everything except the two verbatim upstream
`LICENSE-*-jsonic` files) is MIT licensed, matching the rest of `ext/`.
