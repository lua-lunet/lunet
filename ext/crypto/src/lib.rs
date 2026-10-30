//! lunet.crypto — the libsodium primitive surface for lunet.
//!
//! A standalone cdylib (liblunet_crypto): links its own STATIC libsodium
//! via build.rs and exports the lunet_sodium_* ABI. Independent of every
//! other extension; nothing here touches any other module's state.
//!
//! SECURITY BOUNDARY, stated plainly (docs/SODIUM.md says the same):
//! stateless hashing crosses no secrets; the HMAC KEY is ordinary Lua
//! string data and does cross the FFI unguarded — a documented boundary.
//! This surface is for ordinary primitives (checksums, JWT HS256,
//! passwords), not key custody.

#![deny(unsafe_code)]

use std::cell::RefCell;
use std::os::raw::{c_char, c_int, c_ulonglong};

thread_local! {
    /// The last RC_ERR / RC_INVAL message for this thread. Read via
    /// [`lunet_crypto_last_error`]; the Lua loader copies it out with
    /// ffi.string immediately. Valid until the next fallible call on
    /// this thread.
    static LAST_ERROR: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
}

/// Success.
const RC_OK: c_int = 0;
/// Success with information (verification did not match).
const RC_OK_ABSENT: c_int = 1;
/// OPERATIONAL failure — message in the last-error buffer.
const RC_ERR: c_int = -1;
/// MALFORMED ARGUMENT — message naming the constraint.
const RC_INVAL: c_int = -2;

/// Record an OPERATIONAL failure message and return its code.
fn fail(msg: &str) -> c_int {
    set_last_error(msg.as_bytes());
    RC_ERR
}

/// Record a MALFORMED ARGUMENT message and return its code.
fn invalid(msg: String) -> c_int {
    set_last_error(msg.as_bytes());
    RC_INVAL
}

/// Write the last-error buffer.
fn set_last_error(msg: &[u8]) {
    LAST_ERROR.with(|e| {
        if let Ok(mut e) = e.try_borrow_mut() {
            e.clear();
            e.extend_from_slice(msg);
        }
    });
}

/// Borrow a Lua input string as a slice for one call. The pointer is
/// valid for `len` bytes for the duration of the call (the loader
/// guarantees it by passing live Lua strings straight through).
#[allow(unsafe_code)]
fn buf_in<'a>(ptr: *const u8, len: usize, what: &str) -> Result<&'a [u8], String> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(format!("{what}: null pointer with non-zero length {len}"));
    }
    // SAFETY: non-null checked above; read-only use for this call.
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// Borrow a Lua output buffer as a mutable slice for one call.
#[allow(unsafe_code)]
fn buf_out<'a>(ptr: *mut u8, cap: usize, what: &str) -> Result<&'a mut [u8], String> {
    if cap == 0 {
        return Ok(&mut []);
    }
    if ptr.is_null() {
        return Err(format!("{what}: null output pointer with capacity {cap}"));
    }
    // SAFETY: non-null checked above; caller contract per buf_in.
    Ok(unsafe { std::slice::from_raw_parts_mut(ptr, cap) })
}

/// SHA-256 digest size in bytes, per libsodium (crypto_hash_sha256_BYTES).
const SHA256BYTES: usize = 32;

/// The libsodium extern declarations for this crate: contract comments
/// on every symbol, pointer+length never allowed to disagree.
#[allow(unsafe_code)]
mod sodium_ffi {
    use std::os::raw::{c_char, c_int, c_uchar, c_ulonglong};

    extern "C" {
        /// CONTRACT (libsodium docs, "SHA-2"): one-shot SHA-256. Writes
        /// exactly crypto_hash_sha256_BYTES (32) bytes to `out`; `out`
        /// must have room for them. Returns 0; there is no documented
        /// failure mode for valid buffers.
        pub fn crypto_hash_sha256(
            out: *mut c_uchar,
            in_: *const c_uchar,
            inlen: c_ulonglong,
        ) -> c_int;

        /// CONTRACT (libsodium docs, "HMAC-SHA-2"): one-shot HMAC-SHA-256.
        /// Writes exactly crypto_auth_hmacsha256_BYTES (32) bytes to
        /// `out`; `k` must be exactly crypto_auth_hmacsha256_KEYBYTES
        /// (32) bytes. Returns 0; there is no documented failure mode
        /// for valid buffers.
        pub fn crypto_auth_hmacsha256(
            out: *mut c_uchar,
            in_: *const c_uchar,
            inlen: c_ulonglong,
            k: *const c_uchar,
        ) -> c_int;

        /// CONTRACT (libsodium docs, "Key size"): reports
        /// crypto_auth_hmacsha256_KEYBYTES from the LINKED library (32 in
        /// every libsodium release). Read at call time, never restated as
        /// a literal, so an ABI drift is a detectable runtime error.
        pub fn crypto_auth_hmacsha256_keybytes() -> usize;

        /// CONTRACT (libsodium docs, "Generating random data"): fills
        /// `buf[0..size)` from the system CSPRNG (seeded at
        /// `sodium_init`, reseeded as required). Cannot fail (void
        /// return). The library's own CSPRNG, so a
        /// process never mixes two RNGs.
        pub fn randombytes_buf(buf: *mut c_uchar, size: usize);

        /// CONTRACT (libsodium docs): initialises the library. Returns 0
        /// if already initialised, 1 on first initialisation, -1 on
        /// failure. Idempotent and thread-safe.
        pub fn sodium_init() -> c_int;

        /// CONTRACT (libsodium docs, "Base64"): encodes `bin_len` bytes
        /// from `bin` into `b64`, which must have room for at least
        /// `b64_maxlen` bytes. Writes the NUL terminator and returns
        /// `b64` on success. Returns NULL only when `b64_maxlen` is too
        /// small for the encoded result.
        pub fn sodium_bin2base64(
            b64: *mut c_char,
            b64_maxlen: usize,
            bin: *const c_uchar,
            bin_len: usize,
            variant: c_int,
        ) -> *mut c_char;

        /// CONTRACT (libsodium docs, "Base64"): decodes `b64_len` bytes
        /// of `b64` (skipping any byte listed in `ignore`) directly into
        /// `bin`, which must have room for at least `bin_maxlen` bytes.
        /// Returns 0 and writes the decoded byte count to `*bin_len` on
        /// success; `*b64_end` (if non-NULL) is set to the first byte
        /// after the last valid parsed character — after the input's end
        /// only when the whole string parsed. Returns -1 when the parsed
        /// string would need more than `bin_maxlen` bytes (never
        /// truncating), and for malformed input. There is no diagnostic
        /// string: the error is the binary result.
        pub fn sodium_base642bin(
            bin: *mut c_uchar,
            bin_maxlen: usize,
            b64: *const c_char,
            b64_len: usize,
            ignore: *const c_char,
            bin_len: *mut usize,
            b64_end: *mut *mut c_char,
            variant: c_int,
        ) -> c_int;

        pub fn crypto_pwhash_strbytes() -> usize;

        pub fn crypto_pwhash_str(
            out: *mut c_char,
            passwd: *const c_char,
            passwdlen: c_ulonglong,
            opslimit: c_ulonglong,
            memlimit: usize,
        ) -> c_int;

        pub fn crypto_pwhash_str_verify(
            str_: *const c_char,
            passwd: *const c_char,
            passwdlen: c_ulonglong,
        ) -> c_int;
    }
}

/// Shared prologue: make sure libsodium is initialised before a primitive
/// runs. `sodium_init` is idempotent and thread-safe; later
/// calls are cheap. An init failure is an environment property, reported
/// as an operational error — never a panic.
fn sodium_ready() -> Result<(), String> {
    // sodium_init: 0 already initialised, 1 first init, -1 failure.
    // Per-symbol unsafe allowance: the one call into libsodium's C ABI
    // this crate makes outside the exported shims.
    #[allow(unsafe_code)]
    let rc = unsafe { sodium_ffi::sodium_init() };
    if rc < 0 {
        return Err("libsodium initialisation failed".to_string());
    }
    Ok(())
}

/// One-shot SHA-256. Writes the 32-byte digest to `out` (which must have
/// room for exactly [`SHA256BYTES`] bytes). RC_OK on success; RC_INVAL
/// for a null `out` or a null input with a non-zero length; RC_ERR only
/// when libsodium could not be initialised.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_sodium_sha256(
    input: *const u8,
    input_len: usize,
    out: *mut u8,
) -> c_int {
    if let Err(m) = sodium_ready() {
        return fail(&m);
    }
    let input = match buf_in(input, input_len, "sha256 input") {
        Ok(v) => v,
        Err(m) => return invalid(m),
    };
    if out.is_null() {
        return invalid(format!("sha256 output pointer must not be null ({SHA256BYTES} bytes required)"));
    }
    // SAFETY: out non-null checked above, caller contract guarantees 32
    // writable bytes; input pointer/length derive from one slice.
    let rc = unsafe {
        sodium_ffi::crypto_hash_sha256(out, input.as_ptr(), input.len() as c_ulonglong)
    };
    if rc != 0 {
        return fail("crypto_hash_sha256 returned a non-zero status (undocumented libsodium failure)");
    }
    RC_OK
}

/// One-shot HMAC-SHA-256 (the JWT HS256 primitive). Writes the 32-byte
/// tag to `out` (room for exactly [`SHA256BYTES`] bytes required). `key`
/// must be exactly libsodium's HMAC-SHA-256 key size (32 bytes — read
/// from the linked library at call time, never restated as a literal).
/// RC_OK on success; RC_INVAL for a wrong key length or a null pointer
/// where bytes are required; RC_ERR only when libsodium could not be
/// initialised.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_sodium_hmac_sha256(
    input: *const u8,
    input_len: usize,
    key: *const u8,
    key_len: usize,
    out: *mut u8,
) -> c_int {
    if let Err(m) = sodium_ready() {
        return fail(&m);
    }
    let input = match buf_in(input, input_len, "hmac_sha256 input") {
        Ok(v) => v,
        Err(m) => return invalid(m),
    };
    let key = match buf_in(key, key_len, "hmac_sha256 key") {
        Ok(v) => v,
        Err(m) => return invalid(m),
    };
    if out.is_null() {
        return invalid(format!(
            "hmac_sha256 output pointer must not be null ({SHA256BYTES} bytes required)"
        ));
    }
    // The key size is the LINKED library's constant, not a literal here.
    let want = unsafe { sodium_ffi::crypto_auth_hmacsha256_keybytes() };
    if key.len() != want {
        return invalid(format!(
            "hmac_sha256 key must be exactly {want} bytes, got {}",
            key.len()
        ));
    }
    // SAFETY: out non-null checked above, caller contract guarantees 32
    // writable bytes; both pointer/length pairs derive from one slice.
    let rc = unsafe {
        sodium_ffi::crypto_auth_hmacsha256(
            out,
            input.as_ptr(),
            input.len() as c_ulonglong,
            key.as_ptr(),
        )
    };
    if rc != 0 {
        return fail("crypto_auth_hmacsha256 returned a non-zero status (undocumented libsodium failure)");
    }
    RC_OK
}

/// Fill `out[0..out_len)` with unpredictable bytes from the same CSPRNG
/// draws from the library CSPRNG (never mix two RNGs in one process). A zero length is a
/// successful no-op. RC_OK on success; RC_INVAL for a null `out` with a
/// non-zero length; RC_ERR only when libsodium could not be initialised.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_sodium_randombytes(out: *mut u8, out_len: usize) -> c_int {
    if let Err(m) = sodium_ready() {
        return fail(&m);
    }
    if out_len == 0 {
        return RC_OK;
    }
    if out.is_null() {
        return invalid(format!(
            "randombytes output pointer must not be null ({out_len} bytes requested)"
        ));
    }
    // SAFETY: out non-null checked above; the caller contract guarantees
    // out_len writable bytes.
    unsafe { sodium_ffi::randombytes_buf(out, out_len) };
    RC_OK
}

/// Argon2id password hashing: write a NUL-terminated, self-describing
/// hash string into `out` (room for crypto_pwhash_STRBYTES bytes).
/// `opslimit` / `memlimit` are libsodium's limits. RC_OK on success;
/// RC_INVAL for a null `out` or a null password with non-zero length;
/// RC_ERR on operational failure (libsodium init or hashing failure).
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_sodium_pwhash_str(
    passwd: *const u8,
    passwd_len: usize,
    opslimit: c_ulonglong,
    memlimit: usize,
    out: *mut u8,
    out_cap: usize,
) -> c_int {
    if let Err(m) = sodium_ready() {
        return fail(&m);
    }
    let passwd = match buf_in(passwd, passwd_len, "pwhash_str password") {
        Ok(v) => v,
        Err(m) => return invalid(m),
    };
    if out.is_null() {
        return invalid(format!(
            "pwhash_str output pointer must not be null ({} bytes required)",
            unsafe { sodium_ffi::crypto_pwhash_strbytes() }
        ));
    }
    let need = unsafe { sodium_ffi::crypto_pwhash_strbytes() };
    if out_cap < need {
        return invalid(format!(
            "pwhash_str output buffer too small: {need} bytes required, got {out_cap}"
        ));
    }
    let rc = unsafe {
        sodium_ffi::crypto_pwhash_str(
            out as *mut c_char,
            passwd.as_ptr() as *const c_char,
            passwd.len() as c_ulonglong,
            opslimit,
            memlimit,
        )
    };
    if rc != 0 {
        return fail("crypto_pwhash_str failed (out of memory or invalid limits)");
    }
    RC_OK
}

/// Verify `passwd` against the self-describing hash string `hash`.
/// RC_OK on match; RC_ERR on mismatch or malformed hash; RC_INVAL for
/// malformed C-level arguments.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_sodium_pwhash_str_verify(
    hash: *const u8,
    hash_len: usize,
    passwd: *const u8,
    passwd_len: usize,
) -> c_int {
    if let Err(m) = sodium_ready() {
        return fail(&m);
    }
    let hash = match buf_in(hash, hash_len, "pwhash_str_verify hash") {
        Ok(v) => v,
        Err(m) => return invalid(m),
    };
    let passwd = match buf_in(passwd, passwd_len, "pwhash_str_verify password") {
        Ok(v) => v,
        Err(m) => return invalid(m),
    };
    // crypto_pwhash_str_verify expects NUL-terminated hash string; our
    // hash slice is the full buffer including trailing NUL? The Lua side
    // passes #hash without NUL. libsodium reads until NUL, so append a
    // local NUL-terminated copy.
    let mut buf = vec![0u8; hash.len() + 1];
    buf[..hash.len()].copy_from_slice(hash);
    let rc = unsafe {
        sodium_ffi::crypto_pwhash_str_verify(
            buf.as_ptr() as *const c_char,
            passwd.as_ptr() as *const c_char,
            passwd.len() as c_ulonglong,
        )
    };
    if rc != 0 {
        // libsodium returns -1 for both mismatch and a malformed hash
        // string; both are "not a match" to the caller. Mismatch is a
        // normal result, not an operational failure, so it does not
        // touch last_error (no decryption-oracle-style reason leaking).
        return RC_OK_ABSENT;
    }
    RC_OK
}

/// Base64 variant selection. The values are libsodium's own macro
/// values, mirrored here and in the Lua loader.
/// URLs need `URLSAFE_NO_PADDING` — 7 — the JWT profile, because tokens
/// travel in headers and never carry `=`.
pub const BASE64_VARIANT_ORIGINAL: c_int = 1;
pub const BASE64_VARIANT_ORIGINAL_NO_PADDING: c_int = 3;
pub const BASE64_VARIANT_URLSAFE: c_int = 5;
pub const BASE64_VARIANT_URLSAFE_NO_PADDING: c_int = 7;

/// Encoded length of `bin_len` raw bytes under ANY variant, NUL included:
/// ((bin_len) / 3) * 4 + 5 — the maximum over all variants of the linked
/// library's per-variant `sodium_base64_encoded_len(bin_len, variant)`,
/// so one bound serves every call.
fn base64_encoded_len(bin_len: usize) -> usize {
    (bin_len / 3) * 4 + 5
}

/// Decoded upper bound of `b64_len` encoded bytes under any variant:
/// every 4 encoded characters carry at most 3 raw bytes. Equals the
/// library's own `b64_len / 4 * 3` bound for aligned lengths and exceeds
/// it only to cover the final unpadded group — never below the actual
/// output for any variant.
fn base64_decoded_len(b64_len: usize) -> usize {
    ((b64_len + 3) / 4) * 3
}

/// Encode `input_len` raw bytes under `variant` into `out`, which must
/// have room for `base64_encoded_len(input_len)` bytes. The caller owns
/// the buffer; the result is NUL-terminated by the library, but the
/// caller reads the table value or the return contract, not a NUL.
/// RC_OK on success; RC_INVAL for a null `out`, a null input with a
/// non-zero length, an unknown variant, or a short buffer (a caller bug,
/// loud); RC_ERR only when libsodium could not be initialised.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_sodium_base64_encode(
    input: *const u8,
    input_len: usize,
    variant: c_int,
    out: *mut u8,
    out_cap: usize,
) -> c_int {
    if let Err(m) = sodium_ready() {
        return fail(&m);
    }
    let input = match buf_in(input, input_len, "base64_encode input") {
        Ok(v) => v,
        Err(m) => return invalid(m),
    };
    match variant {
        BASE64_VARIANT_ORIGINAL
        | BASE64_VARIANT_ORIGINAL_NO_PADDING
        | BASE64_VARIANT_URLSAFE
        | BASE64_VARIANT_URLSAFE_NO_PADDING => {}
        other => {
            return invalid(format!("base64_encode: unknown variant {other}"));
        }
    }
    if out.is_null() {
        return invalid(format!(
            "base64_encode output pointer must not be null ({} bytes required)",
            base64_encoded_len(input_len)
        ));
    }
    if out_cap < base64_encoded_len(input_len) {
        return invalid(format!(
            "base64_encode output buffer too small: {} bytes required (NUL included), got {out_cap}",
            base64_encoded_len(input_len)
        ));
    }
    // SAFETY: out non-null checked above with the encoded-length contract
    // verified; input pointer/length derive from one slice.
    let end = unsafe {
        sodium_ffi::sodium_bin2base64(
            out as *mut c_char,
            base64_encoded_len(input_len),
            input.as_ptr(),
            input_len,
            variant,
        )
    };
    if end.is_null() {
        return fail("sodium_bin2base64 returned NULL (unsupported variant is pre-validated; this is an undocumented libsodium failure)");
    }
    RC_OK
}

/// Decode `input_len` bytes of base64 under `variant` into `out`, which
/// must have room for `base64_decoded_len(input_len)` bytes; the actual
/// byte count is written to `written` (the decoded bytes are binary —
/// length, never a NUL, says where they end). The library decodes
/// directly into the caller's buffer — no transient allocation, no
/// freeing — and `written` is the library's own decoded-byte count. The
/// full input must parse (b64_end must land on the input's end) or the
/// call is invalid — a whole-string decode, no tail. RC_OK on success;
/// RC_INVAL for malformed input (one opaque reject — wrong alphabet, bad
/// length, stray characters, unknown variant — the error is the binary
/// result, no per-reason message), a null `out`, a null input with a
/// non-zero length, or a short buffer; RC_ERR only when libsodium could
/// not be initialised.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_sodium_base64_decode(
    input: *const u8,
    input_len: usize,
    variant: c_int,
    out: *mut u8,
    out_cap: usize,
    written: *mut usize,
) -> c_int {
    if let Err(m) = sodium_ready() {
        return fail(&m);
    }
    if written.is_null() {
        return invalid("base64_decode written pointer must not be null".to_string());
    }
    let input = match buf_in(input, input_len, "base64_decode input") {
        Ok(v) => v,
        Err(m) => return invalid(m),
    };
    match variant {
        BASE64_VARIANT_ORIGINAL
        | BASE64_VARIANT_ORIGINAL_NO_PADDING
        | BASE64_VARIANT_URLSAFE
        | BASE64_VARIANT_URLSAFE_NO_PADDING => {}
        other => {
            return invalid(format!("base64_decode: unknown variant {other}"));
        }
    }
    if out.is_null() {
        return invalid(format!(
            "base64_decode output pointer must not be null ({} bytes required)",
            base64_decoded_len(input_len)
        ));
    }
    if out_cap < base64_decoded_len(input_len) {
        return invalid(format!(
            "base64_decode output buffer too small: {} bytes required, got {out_cap}",
            base64_decoded_len(input_len)
        ));
    }
    let mut count: usize = 0;
    let mut end: *mut c_char = std::ptr::null_mut();
    // SAFETY: bin/b64 pointers and lengths are consistent (slice-derived
    // or pre-validated), bin_maxlen matches the documented upper bound,
    // and out is within the bounds checked above.
    let rc = unsafe {
        sodium_ffi::sodium_base642bin(
            out,
            base64_decoded_len(input_len),
            input.as_ptr() as *const c_char,
            input_len,
            std::ptr::null(),
            &mut count,
            &mut end,
            variant,
        )
    };
    if rc != 0 {
        return invalid(
            "base64_decode: malformed base64 (the library refused to decode)".to_string(),
        );
    }
    // Full consumption: a whole-string decode, no tail. b64_end has been
    // set and points within the input slice just passed.
    let consumed = end as usize - input.as_ptr() as usize;
    if consumed != input_len {
        return invalid(format!(
            "base64_decode: unparseable input at byte {} (of {input_len})",
            consumed
        ));
    }
    // SAFETY: the contract guarantees `written` is writable.
    unsafe { *written = count };
    RC_OK
}

/// The last RC_ERR / RC_INVAL message for this thread: a borrowed
/// pointer plus length (NOT NUL-terminated; use the length). Valid until
/// the next fallible call on this thread — the loader copies it out with
/// `ffi.string` immediately.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_crypto_last_error(len: *mut usize) -> *const u8 {
    LAST_ERROR.with(|e| {
        let e = match e.try_borrow() {
            Ok(e) => e,
            Err(_) => return std::ptr::null(),
        };
        if !len.is_null() {
            // SAFETY: non-null checked; single usize write.
            unsafe { *len = e.len() };
        }
        e.as_ptr()
    })
}

/// Crate version as a NUL-terminated static string.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn lunet_crypto_version() -> *const c_char {
    b"0.1.0\0".as_ptr() as *const c_char
}
