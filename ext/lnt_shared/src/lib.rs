//! # lnt-shared — lunet-style shared dictionary for LuaJIT (Linux / macOS)
//!
//! This library provides a shared dictionary API for LuaJIT programs running
//! under lunet. It is a pure opt-in extension.
//!
//! ## Design
//!
//! * One anonymous `mmap(MAP_SHARED|MAP_ANONYMOUS)` region per named dictionary.
//! * All dictionary state lives inside the mmap'd region — no heap allocation
//!   for persistent data.
//! * A single spinlock in the region header serialises all mutations.
//! * Open-address hash table (FNV-1a, linear probing).
//! * Bump allocator for entry storage; freed space is not reclaimed until
//!   `flush_all` is called.
//!
//! ## Platforms
//!
//! Linux and macOS.  Windows is not supported by this crate; a separate
//! implementation using `CreateFileMapping`/`MapViewOfFile` would be needed.
//!
//! ## C ABI
//!
//! LuaJIT accesses this library exclusively through the stable C ABI exported
//! below. The opaque `*mut c_void` handle is a `Box<NgxSharedHandle>` whose
//! lifetime is managed by `ngx_shared_open` / `ngx_shared_close` (legacy symbol
//! names retained for ABI compatibility).

// Low-level systems code: unsafe fn bodies intentionally contain raw pointer
// operations.  The explicit unsafe block per-operation style required by
// Rust 2024 would add noise without safety benefit in this FFI-heavy module.
#![allow(unsafe_op_in_unsafe_fn)]

mod dict;
mod region;
mod time;

use dict::{Dict, NGX_SHARED_ERR_INVAL, NGX_SHARED_NOT_FOUND, NGX_SHARED_OK, lens_valid};

use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_void};
use std::sync::{Arc, Mutex, OnceLock};

// ── Global dictionary registry ────────────────────────────────────────────────

/// Maps a dictionary name to its shared `Dict`.  Multiple calls to
/// `ngx_shared_open` with the same name return handles that reference the
/// same underlying region.
static REGISTRY: OnceLock<Mutex<HashMap<String, Arc<Dict>>>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<String, Arc<Dict>>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

// ── Opaque handle ─────────────────────────────────────────────────────────────

/// The value behind a `*mut c_void` handle returned to C callers.
struct NgxSharedHandle {
    dict: Arc<Dict>,
}

type Handle = *mut NgxSharedHandle;

/// Dereference a handle pointer, returning `None` if it is null.
#[inline]
unsafe fn handle<'a>(h: *mut c_void) -> Option<&'a NgxSharedHandle> {
    if h.is_null() {
        None
    } else {
        Some(&*(h as Handle))
    }
}

/// Get the `Dict` for a handle, or return the `Err` given to the caller.
macro_rules! dict_of {
    ($h:expr) => {
        match handle($h) {
            Some(hnd) => &hnd.dict,
            None => return NGX_SHARED_NOT_FOUND,
        }
    };
}

/// Materialise the key slice for read-only ops.
/// Validates length *before* slicing (an oversized klen over a small buffer
/// would otherwise be instant UB).
#[inline]
unsafe fn kslice<'a>(key: *const u8, klen: usize) -> Result<&'a [u8], i32> {
    if key.is_null() {
        return Err(NGX_SHARED_NOT_FOUND);
    }
    if !lens_valid(klen, 0) {
        return Err(NGX_SHARED_ERR_INVAL);
    }
    Ok(std::slice::from_raw_parts(key, klen))
}

/// Materialise (key, val) slices for mutating ops.  A null/empty val maps to
/// an empty slice (setting an empty value is legal).
#[inline]
unsafe fn kvslices<'a>(
    key: *const u8,
    klen: usize,
    val: *const u8,
    vlen: usize,
) -> Result<(&'a [u8], &'a [u8]), i32> {
    let k = kslice(key, klen)?;
    if !lens_valid(0, vlen) {
        return Err(NGX_SHARED_ERR_INVAL);
    }
    let v = if val.is_null() || vlen == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(val, vlen)
    };
    Ok((k, v))
}

// ── FFI exports ───────────────────────────────────────────────────────────────

/// Open (or create) a named dictionary of at least `size_bytes` bytes.
///
/// If a dictionary with the same name has already been opened in this process,
/// the existing region is returned (the `size_bytes` argument is ignored for
/// subsequent opens).
///
/// Returns an opaque handle on success, or `NULL` on failure.
///
/// # Safety
/// `name` must be a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_open(
    name: *const c_char,
    size_bytes: u64,
) -> *mut c_void {
    if name.is_null() {
        return std::ptr::null_mut();
    }
    let name_str = match CStr::from_ptr(name).to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => return std::ptr::null_mut(),
    };

    let mut reg = match registry().lock() {
        Ok(g) => g,
        Err(_) => return std::ptr::null_mut(),
    };

    // NB: never panic here — unwinding out of an `extern "C"` export aborts
    // the host process.  A failed mmap must yield a NULL handle instead.
    let dict = match reg.entry(name_str) {
        std::collections::hash_map::Entry::Occupied(e) => e.get().clone(),
        std::collections::hash_map::Entry::Vacant(e) => {
            // Minimum 64 KiB; use caller's size if larger.
            let sz = (size_bytes as usize).max(65536);
            match Dict::new(sz) {
                Some(d) => e.insert(Arc::new(d)).clone(),
                None => return std::ptr::null_mut(),
            }
        }
    };

    let handle = Box::new(NgxSharedHandle { dict });
    Box::into_raw(handle) as *mut c_void
}

/// Close a handle obtained from `ngx_shared_open`.
///
/// The underlying region is **not** freed until all handles to it are closed.
///
/// # Safety
/// `handle` must be a pointer previously returned by `ngx_shared_open` and
/// not yet passed to `ngx_shared_close`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_close(h: *mut c_void) {
    if h.is_null() {
        return;
    }
    drop(Box::from_raw(h as Handle));
}

/// Retrieve the value for `key`.
///
/// On success:
/// * `*out_val` is set to a heap-allocated buffer containing the value bytes.
///   The caller **must** free this buffer with `ngx_shared_free_bytes`.
/// * `*out_len` is set to the number of bytes in `*out_val`.
/// * `*out_type` is set to the value type (`0`=bytes, `1`=f64, `2`=bool).
/// * Returns `0`.
///
/// On failure returns a negative error code and does not write to the
/// out-parameters.
///
/// # Safety
/// All pointer arguments must be valid.  `key` need not be NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_get(
    h: *mut c_void,
    key: *const u8,
    klen: usize,
    out_val: *mut *mut u8,
    out_len: *mut usize,
    out_type: *mut c_int,
) -> c_int {
    let dict = dict_of!(h);
    if out_val.is_null() || out_len.is_null() || out_type.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = match kslice(key, klen) {
        Ok(k) => k,
        Err(e) => return e,
    };
    match dict.get(key_slice) {
        Err(e) => e,
        Ok((val, vtype)) => {
            let len = val.len();
            // Hand ownership across the FFI as a boxed slice: unlike Vec,
            // Box<[u8]> carries no capacity, so reconstructing it in
            // ngx_shared_free_bytes from (ptr, len) alone is unambiguous.
            let ptr = Box::into_raw(val.into_boxed_slice()) as *mut u8;
            *out_val = ptr;
            *out_len = len;
            *out_type = vtype as c_int;
            NGX_SHARED_OK
        }
    }
}

/// Free a buffer returned by `ngx_shared_get`.
///
/// # Safety
/// `p` must be a pointer previously returned in `*out_val` by `ngx_shared_get`
/// with its original length in `len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_free_bytes(p: *mut u8, len: usize) {
    if p.is_null() {
        return;
    }
    drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)));
}

/// Set `key` to the given value, overwriting any existing entry.
///
/// `val_type`: `0`=raw bytes, `1`=f64 (8 bytes LE), `2`=bool (1 byte).
/// `ttl_secs`: seconds until expiry; `<= 0` means no expiry.
///
/// Returns `0` on success or a negative error code.
///
/// # Safety
/// All pointer arguments must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_set(
    h: *mut c_void,
    key: *const u8,
    klen: usize,
    val: *const u8,
    vlen: usize,
    val_type: c_int,
    ttl_secs: f64,
) -> c_int {
    let dict = dict_of!(h);
    match kvslices(key, klen, val, vlen) {
        Err(e) => e,
        Ok((k, v)) => dict.set(k, v, val_type as u8, ttl_secs),
    }
}

/// Set `key` only if it does not already exist.
///
/// Returns `0` on success, `-2` if the key already exists, or another
/// negative error code on failure.
///
/// # Safety
/// All pointer arguments must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_add(
    h: *mut c_void,
    key: *const u8,
    klen: usize,
    val: *const u8,
    vlen: usize,
    val_type: c_int,
    ttl_secs: f64,
) -> c_int {
    let dict = dict_of!(h);
    match kvslices(key, klen, val, vlen) {
        Err(e) => e,
        Ok((k, v)) => dict.add(k, v, val_type as u8, ttl_secs),
    }
}

/// Set `key` only if it already exists.
///
/// Returns `0` on success, `-1` if the key does not exist, or another
/// negative error code on failure.
///
/// # Safety
/// All pointer arguments must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_replace(
    h: *mut c_void,
    key: *const u8,
    klen: usize,
    val: *const u8,
    vlen: usize,
    val_type: c_int,
    ttl_secs: f64,
) -> c_int {
    let dict = dict_of!(h);
    match kvslices(key, klen, val, vlen) {
        Err(e) => e,
        Ok((k, v)) => dict.replace(k, v, val_type as u8, ttl_secs),
    }
}

/// Delete `key` from the dictionary.
///
/// Returns `0` on success, `-1` if the key did not exist.
///
/// # Safety
/// All pointer arguments must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_delete(
    h: *mut c_void,
    key: *const u8,
    klen: usize,
) -> c_int {
    let dict = dict_of!(h);
    match kslice(key, klen) {
        Err(e) => e,
        Ok(k) => dict.delete(k),
    }
}

/// Atomically increment a numeric key.
///
/// `delta` is added to the current value.  If the key does not exist and
/// `has_init` is non-zero, the key is initialised to `init` before the
/// increment is applied.
///
/// `ttl_secs <= 0` means:
/// * For a new key: no expiry.
/// * For an existing key: preserve the existing expiry.
///
/// On success writes the new value into `*result` and returns `0`.
///
/// # Safety
/// `result` must be a valid pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_incr(
    h: *mut c_void,
    key: *const u8,
    klen: usize,
    delta: f64,
    init: f64,
    has_init: c_int,
    ttl_secs: f64,
    result: *mut f64,
) -> c_int {
    let dict = dict_of!(h);
    if result.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = match kslice(key, klen) {
        Ok(k) => k,
        Err(e) => return e,
    };
    let mut out: f64 = 0.0;
    let rc = dict.incr(key_slice, delta, init, has_init != 0, ttl_secs, &mut out);
    if rc == NGX_SHARED_OK {
        *result = out;
    }
    rc
}

/// Update the TTL of an existing key.
///
/// `ttl_secs <= 0` removes the expiry (key will not expire).
///
/// Returns `0` on success, `-1` if the key does not exist.
///
/// # Safety
/// All pointer arguments must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_expire(
    h: *mut c_void,
    key: *const u8,
    klen: usize,
    ttl_secs: f64,
) -> c_int {
    let dict = dict_of!(h);
    match kslice(key, klen) {
        Err(e) => e,
        Ok(k) => dict.expire(k, ttl_secs),
    }
}

/// Get the remaining TTL in seconds for `key`.
///
/// Writes the remaining TTL into `*out_ttl` and returns:
/// * `0`  — key exists and has an expiry (`*out_ttl` is set to remaining seconds).
/// * `1`  — key exists but has no expiry (`*out_ttl` is set to `-1.0`).
/// * `-1` — key does not exist.
///
/// # Safety
/// All pointer arguments must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_ttl(
    h: *mut c_void,
    key: *const u8,
    klen: usize,
    out_ttl: *mut f64,
) -> c_int {
    let dict = dict_of!(h);
    if out_ttl.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = match kslice(key, klen) {
        Ok(k) => k,
        Err(e) => return e,
    };
    match dict.ttl(key_slice) {
        Err(e) => e,
        Ok(None) => {
            *out_ttl = -1.0;
            1 // exists, no expiry
        }
        Ok(Some(secs)) => {
            *out_ttl = secs;
            NGX_SHARED_OK
        }
    }
}

/// Remove all entries from the dictionary and reset the allocator.
///
/// # Safety
/// `h` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_flush_all(h: *mut c_void) {
    if let Some(hnd) = handle(h) {
        hnd.dict.flush_all();
    }
}

/// Scan the dictionary and evict expired entries.
///
/// `max <= 0` means scan all entries.  Returns the number of entries evicted.
///
/// # Safety
/// `h` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_flush_expired(h: *mut c_void, max: c_int) -> c_int {
    match handle(h) {
        Some(hnd) => hnd.dict.flush_expired(max),
        None => 0,
    }
}

/// Returns the total capacity of the region in bytes.
///
/// # Safety
/// `h` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_capacity(h: *mut c_void) -> u64 {
    match handle(h) {
        Some(hnd) => hnd.dict.capacity(),
        None => 0,
    }
}

/// Returns the approximate number of free bytes remaining in the data area.
///
/// Note: freed/tombstoned entries do not contribute to free space until
/// `flush_all` is called.
///
/// # Safety
/// `h` must be a valid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ngx_shared_free_space(h: *mut c_void) -> u64 {
    match handle(h) {
        Some(hnd) => hnd.dict.free_space(),
        None => 0,
    }
}

// ── FFI-level tests ───────────────────────────────────────────────────────────

#[cfg(test)]
mod ffi_tests {
    use super::*;
    use std::ffi::CString;

    /// Open a dictionary with a test-unique name (the registry is global).
    fn open_unique(name: &str, size: u64) -> *mut c_void {
        let c = CString::new(name).unwrap();
        unsafe { ngx_shared_open(c.as_ptr(), size) }
    }

    #[test]
    fn test_ffi_open_null_name_returns_null() {
        let h = unsafe { ngx_shared_open(std::ptr::null(), 65536) };
        assert!(h.is_null());
    }

    #[test]
    fn test_ffi_open_absurd_size_returns_null_not_abort() {
        // mmap of u64::MAX bytes must fail; open must return NULL gracefully
        // rather than panic (panic = "abort" in release would kill the host
        // Lua process).
        let c = CString::new("ffi_absurd_size").unwrap();
        let h = unsafe { ngx_shared_open(c.as_ptr(), u64::MAX) };
        assert!(h.is_null(), "absurd size must yield NULL handle");
    }

    #[test]
    fn test_ffi_open_close_roundtrip() {
        let h = open_unique("ffi_rt", 65536);
        assert!(!h.is_null());
        unsafe { ngx_shared_close(h) };
        // Closing NULL must be a no-op.
        unsafe { ngx_shared_close(std::ptr::null_mut()) };
    }

    #[test]
    fn test_ffi_set_get_free_roundtrip() {
        let h = open_unique("ffi_sg", 65536);
        assert!(!h.is_null());
        unsafe {
            let rc = ngx_shared_set(h, b"key".as_ptr(), 3, b"value".as_ptr(), 5, 0, 0.0);
            assert_eq!(rc, NGX_SHARED_OK);

            let mut out_val: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let mut out_type: c_int = -99;
            let rc = ngx_shared_get(h, b"key".as_ptr(), 3, &mut out_val, &mut out_len, &mut out_type);
            assert_eq!(rc, NGX_SHARED_OK);
            assert_eq!(out_len, 5);
            assert_eq!(out_type, 0);
            assert_eq!(std::slice::from_raw_parts(out_val, out_len), b"value");
            ngx_shared_free_bytes(out_val, out_len);
            // Freeing NULL is a no-op.
            ngx_shared_free_bytes(std::ptr::null_mut(), 0);

            ngx_shared_close(h);
        }
    }

    #[test]
    fn test_ffi_get_missing_key() {
        let h = open_unique("ffi_miss", 65536);
        assert!(!h.is_null());
        unsafe {
            let mut out_val: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let mut out_type: c_int = 0;
            let rc = ngx_shared_get(h, b"no".as_ptr(), 2, &mut out_val, &mut out_len, &mut out_type);
            assert_eq!(rc, NGX_SHARED_NOT_FOUND);
            assert!(out_val.is_null(), "failed get must not write out_val");
            ngx_shared_close(h);
        }
    }

    #[test]
    fn test_ffi_null_handle_is_robust() {
        unsafe {
            let null = std::ptr::null_mut();
            let mut out_val: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let mut out_type: c_int = 0;
            let mut out_f64: f64 = 0.0;

            assert_eq!(ngx_shared_get(null, b"k".as_ptr(), 1, &mut out_val, &mut out_len, &mut out_type), NGX_SHARED_NOT_FOUND);
            assert_eq!(ngx_shared_set(null, b"k".as_ptr(), 1, b"v".as_ptr(), 1, 0, 0.0), NGX_SHARED_NOT_FOUND);
            assert_eq!(ngx_shared_add(null, b"k".as_ptr(), 1, b"v".as_ptr(), 1, 0, 0.0), NGX_SHARED_NOT_FOUND);
            assert_eq!(ngx_shared_replace(null, b"k".as_ptr(), 1, b"v".as_ptr(), 1, 0, 0.0), NGX_SHARED_NOT_FOUND);
            assert_eq!(ngx_shared_delete(null, b"k".as_ptr(), 1), NGX_SHARED_NOT_FOUND);
            assert_eq!(ngx_shared_incr(null, b"k".as_ptr(), 1, 1.0, 0.0, 1, 0.0, &mut out_f64), NGX_SHARED_NOT_FOUND);
            assert_eq!(ngx_shared_expire(null, b"k".as_ptr(), 1, 1.0), NGX_SHARED_NOT_FOUND);
            assert_eq!(ngx_shared_ttl(null, b"k".as_ptr(), 1, &mut out_f64), NGX_SHARED_NOT_FOUND);
            ngx_shared_flush_all(null); // no-op, must not crash
            assert_eq!(ngx_shared_flush_expired(null, 0), 0);
            assert_eq!(ngx_shared_capacity(null), 0);
            assert_eq!(ngx_shared_free_space(null), 0);
        }
    }

    #[test]
    fn test_ffi_null_key_rejected() {
        let h = open_unique("ffi_nk", 65536);
        assert!(!h.is_null());
        unsafe {
            assert_eq!(ngx_shared_set(h, std::ptr::null(), 1, b"v".as_ptr(), 1, 0, 0.0), NGX_SHARED_NOT_FOUND);
            assert_eq!(ngx_shared_delete(h, std::ptr::null(), 1), NGX_SHARED_NOT_FOUND);
            let mut out_val: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let mut out_type: c_int = 0;
            assert_eq!(ngx_shared_get(h, std::ptr::null(), 1, &mut out_val, &mut out_len, &mut out_type), NGX_SHARED_NOT_FOUND);
            ngx_shared_close(h);
        }
    }

    #[test]
    fn test_ffi_shared_region_between_handles() {
        let h1 = open_unique("ffi_shared", 65536);
        let h2 = open_unique("ffi_shared", 65536);
        assert!(!h1.is_null() && !h2.is_null());
        unsafe {
            assert_eq!(ngx_shared_set(h1, b"k".as_ptr(), 1, b"v".as_ptr(), 1, 0, 0.0), NGX_SHARED_OK);
            let mut out_val: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let mut out_type: c_int = 0;
            assert_eq!(ngx_shared_get(h2, b"k".as_ptr(), 1, &mut out_val, &mut out_len, &mut out_type), NGX_SHARED_OK);
            assert_eq!(std::slice::from_raw_parts(out_val, out_len), b"v");
            ngx_shared_free_bytes(out_val, out_len);
            ngx_shared_close(h1);
            ngx_shared_close(h2);
        }
    }

    #[test]
    fn test_ffi_incr_and_ttl_semantics() {
        let h = open_unique("ffi_incr", 65536);
        assert!(!h.is_null());
        unsafe {
            let mut result: f64 = 0.0;
            // incr with init creates the key.
            assert_eq!(ngx_shared_incr(h, b"c".as_ptr(), 1, 1.0, 0.0, 1, 0.0, &mut result), NGX_SHARED_OK);
            assert_eq!(result, 1.0);
            // Key without expiry: ttl returns 1 and out_ttl = -1.
            let mut ttl: f64 = 0.0;
            assert_eq!(ngx_shared_ttl(h, b"c".as_ptr(), 1, &mut ttl), 1);
            assert_eq!(ttl, -1.0);
            // Key with expiry: ttl returns 0 and remaining seconds.
            assert_eq!(ngx_shared_set(h, b"e".as_ptr(), 1, b"v".as_ptr(), 1, 0, 30.0), NGX_SHARED_OK);
            assert_eq!(ngx_shared_ttl(h, b"e".as_ptr(), 1, &mut ttl), NGX_SHARED_OK);
            assert!(ttl > 0.0 && ttl <= 30.0, "ttl={ttl}");
            // Missing key: ttl returns NOT_FOUND.
            assert_eq!(ngx_shared_ttl(h, b"x".as_ptr(), 1, &mut ttl), NGX_SHARED_NOT_FOUND);
            ngx_shared_close(h);
        }
    }

    #[test]
    fn test_ffi_capacity_and_free_space() {
        let h = open_unique("ffi_cap", 65536);
        assert!(!h.is_null());
        unsafe {
            assert_eq!(ngx_shared_capacity(h), 65536);
            let free = ngx_shared_free_space(h);
            assert!(free > 0 && free < 65536, "free={free}");
            ngx_shared_close(h);
        }
    }

    #[test]
    fn test_ffi_oversized_key_rejected_before_slicing() {
        // klen > u32::MAX would truncate in the on-disk u32 key_len field.
        // The FFI must reject it *before* materialising the slice (which
        // would be instant UB for a 4 GiB "key" over a 1-byte buffer).
        let h = open_unique("ffi_oversize", 65536);
        assert!(!h.is_null());
        let huge = (u32::MAX as usize) + 1;
        unsafe {
            let key = b"k";
            assert_eq!(
                ngx_shared_set(h, key.as_ptr(), huge, b"v".as_ptr(), 1, 0, 0.0),
                NGX_SHARED_ERR_INVAL
            );
            assert_eq!(
                ngx_shared_add(h, key.as_ptr(), huge, b"v".as_ptr(), 1, 0, 0.0),
                NGX_SHARED_ERR_INVAL
            );
            assert_eq!(
                ngx_shared_replace(h, key.as_ptr(), huge, b"v".as_ptr(), 1, 0, 0.0),
                NGX_SHARED_ERR_INVAL
            );
            let mut out_f64: f64 = 0.0;
            assert_eq!(
                ngx_shared_incr(h, key.as_ptr(), huge, 1.0, 0.0, 1, 0.0, &mut out_f64),
                NGX_SHARED_ERR_INVAL
            );
            // Oversized *value* is likewise rejected.
            assert_eq!(
                ngx_shared_set(h, key.as_ptr(), 1, b"v".as_ptr(), huge, 0, 0.0),
                NGX_SHARED_ERR_INVAL
            );
            ngx_shared_close(h);
        }
    }
}
