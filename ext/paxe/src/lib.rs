//! # lunet-paxe
//!
//! PAXE datagram encryption for lunet, built as a `cdylib` and loaded at
//! runtime by the `lunet.paxe` Lua module through the LuaJIT FFI (the same
//! loading model as `ext/jsonic`). This crate is the Rust replacement for
//! the deleted `src/paxe.c`; it is a pure opt-in extension and is never
//! linked into `lunet-run`.
//!
//! This crate so far: build plumbing, the libsodium FFI boundary
//! ([`sodium`], item02), the secure keystore ([`keystore`], item03), the
//! cryptography-free header/flags codec ([`codec`], item04), standard-mode
//! seal/open with the single AAD construction point ([`standard`],
//! item05), DEK-mode seal/open plus the automatic mode-selection layer
//! ([`dek`], item06), and one exported symbol ([`lunet_paxe_version`])
//! proving the end-to-end path — cargo builds the cdylib, the Lua loader
//! finds it, `require` succeeds, and a call returns. The Lua-facing API
//! (item07) has not landed yet.
//!
//! ## Dependency policy: zero crates
//!
//! This crate has **no** crate dependencies — not even `libc`. All
//! cryptography and all secure-memory handling comes from libsodium via
//! hand-written `extern "C"` declarations in [`sodium`], **statically
//! linked into this cdylib** (owner decision, implemented in `build.rs`):
//! `sodium_malloc` / `sodium_mlock` / `sodium_memzero` provide guarded,
//! locked, reliably-zeroed key storage, which is exactly where
//! sysadmin-injected shared cluster keys belong.
//!
//! ## NO PANIC ON ANY INPUT — hard constraint
//!
//! The release profile sets `panic = "abort"`, because unwinding across an
//! FFI boundary into LuaJIT is undefined behaviour. The consequence is
//! absolute: **any Rust panic aborts the entire LuaJIT host process**,
//! taking down every coroutine, socket and connection it serves. A panic
//! must therefore be *impossible* on any input, not merely unlikely:
//!
//! - No indexing, slicing or arithmetic on attacker-controlled datagram
//!   bytes that can panic: no `buf[i]`, no `a + b` on untrusted lengths, no
//!   `unwrap`/`expect` on anything derived from the wire.
//! - Use `get()`, `chunks_exact()`, checked arithmetic and explicit error
//!   returns instead.
//! - Every `extern "C"` entry point validates every pointer and length
//!   before use.
//!
//! This constraint is written here now, while the crate is empty, so the
//! codec, keystore and AEAD items that follow are designed under it from
//! their first line rather than having it retrofitted.
//!
//! ## FFI containment (item02)
//!
//! [`sodium`] is the ONLY module in this crate that may contain an
//! `extern "C"` block or call libsodium, and the only module permitted
//! `unsafe` code (enforced below by `#![deny(unsafe_code)]` with a single
//! module-level exception). It declares the libsodium primitives by hand
//! — zero crate dependencies, not even `libc` — each with its contract
//! written at the declaration, and exposes safe wrappers: fixed-size
//! key/nonce/tag newtypes, slice-derived pointer+length pairs, a startup
//! ABI size check, CSPRNG-only nonce generation, guarded allocations, and
//! AES-GCM unavailability as a reportable error. libsodium is statically
//! linked into this cdylib by `build.rs` (owner decision).

// Every module except sodium.rs is plain safe Rust; unsafe is denied here
// and re-allowed by inner attribute inside sodium.rs alone.
#![deny(unsafe_code)]

mod codec;
mod dek;
mod keystore;
mod sodium;
mod standard;

use std::os::raw::c_char;

/// Crate version as a NUL-terminated static string, baked into the cdylib's
/// read-only data. Built from `CARGO_PKG_VERSION` at compile time so this
/// string and the manifest can never disagree.
static VERSION: &[u8] = concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes();

/// Return the crate version as a pointer to a NUL-terminated UTF-8 string.
///
/// The pointer borrows a `'static` allocation; the caller must NOT free it.
/// Cannot fail and cannot panic: no input, no allocation, no indexing. This
/// is the scaffold symbol proving the build → `require` → call path.
// `#[no_mangle]` is an unsafe attribute (RFC 3325) and so falls under the
// crate's deny(unsafe_code); exporting C ABI symbols is the one legitimate
// use beside sodium.rs, allowed here per-symbol.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_paxe_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    // Reading back the exported C string inherently dereferences a raw
    // pointer; test-only, and it never ships in the cdylib.
    #![allow(unsafe_code)]

    use super::*;
    use std::ffi::CStr;

    #[test]
    fn version_is_nul_terminated_and_matches_manifest() {
        let ptr = lunet_paxe_version();
        assert!(!ptr.is_null());
        let s = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
        assert_eq!(s, env!("CARGO_PKG_VERSION"));
    }
}
