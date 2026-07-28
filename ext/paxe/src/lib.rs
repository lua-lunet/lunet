//! # lunet-paxe
//!
//! PAXE datagram encryption for lunet, built as a `cdylib` and loaded at
//! runtime by the `lunet.paxe` Lua module through the LuaJIT FFI (the same
//! loading model as `ext/jsonic`). This crate is the Rust replacement for
//! the deleted `src/paxe.c`; it is a pure opt-in extension and is never
//! linked into `lunet-run`.
//!
//! This is the scaffold commit: build plumbing plus one exported symbol
//! ([`lunet_paxe_version`]) proving the end-to-end path — cargo builds the
//! cdylib, the Lua loader finds it, `require` succeeds, and a call returns.
//! There is no protocol logic, no cryptography and no keystore yet.
//!
//! ## Dependency policy: zero crates
//!
//! This crate has **no** crate dependencies — not even `libc`. All
//! cryptography and all secure-memory handling will come from libsodium via
//! `extern "C"` declarations (item02), **statically linked into this
//! cdylib** (owner decision): `sodium_malloc` / `sodium_mlock` /
//! `sodium_memzero` provide guarded, locked, reliably-zeroed key storage,
//! which is exactly where sysadmin-injected shared cluster keys belong.
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
#[no_mangle]
pub extern "C" fn lunet_paxe_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
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
