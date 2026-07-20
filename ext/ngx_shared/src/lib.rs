//! # ngx-shared — nginx-style shared dictionary for LuaJIT (Linux / macOS)
//!
//! This library provides a `ngx.shared.DICT`-inspired API for LuaJIT programs
//! running under lunet.  It is **not** a dependency on nginx or OpenResty, and
//! makes **no guarantee** of identical behaviour for any undefined or
//! implementation-specific aspects of OpenResty.  It is a pure opt-in
//! extension that provides a convenient shared-dictionary API.
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
//! below.  The opaque `*mut c_void` handle is a `Box<NgxSharedHandle>` whose
//! lifetime is managed by `ngx_shared_open` / `ngx_shared_close`.

// Low-level systems code: unsafe fn bodies intentionally contain raw pointer
// operations.  The explicit unsafe block per-operation style required by
// Rust 2024 would add noise without safety benefit in this FFI-heavy module.
#![allow(unsafe_op_in_unsafe_fn)]

mod dict;
mod region;
mod time;

use dict::{Dict, NGX_SHARED_NOT_FOUND, NGX_SHARED_OK};

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

    let dict = reg
        .entry(name_str)
        .or_insert_with(|| {
            // Minimum 64 KiB; use caller's size if larger.
            let sz = (size_bytes as usize).max(65536);
            Arc::new(Dict::new(sz).expect("ngx_shared: mmap failed"))
        })
        .clone();

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
    let dict = match handle(h) {
        Some(hnd) => &hnd.dict,
        None => return NGX_SHARED_NOT_FOUND,
    };
    if key.is_null() || out_val.is_null() || out_len.is_null() || out_type.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = std::slice::from_raw_parts(key, klen);
    match dict.get(key_slice) {
        Err(e) => e,
        Ok((val, vtype)) => {
            let len = val.len();
            let ptr = val.leak().as_mut_ptr();
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
    drop(Vec::from_raw_parts(p, len, len));
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
    let dict = match handle(h) {
        Some(hnd) => &hnd.dict,
        None => return NGX_SHARED_NOT_FOUND,
    };
    if key.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = std::slice::from_raw_parts(key, klen);
    let val_slice = if val.is_null() || vlen == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(val, vlen)
    };
    dict.set(key_slice, val_slice, val_type as u8, ttl_secs)
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
    let dict = match handle(h) {
        Some(hnd) => &hnd.dict,
        None => return NGX_SHARED_NOT_FOUND,
    };
    if key.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = std::slice::from_raw_parts(key, klen);
    let val_slice = if val.is_null() || vlen == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(val, vlen)
    };
    dict.add(key_slice, val_slice, val_type as u8, ttl_secs)
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
    let dict = match handle(h) {
        Some(hnd) => &hnd.dict,
        None => return NGX_SHARED_NOT_FOUND,
    };
    if key.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = std::slice::from_raw_parts(key, klen);
    let val_slice = if val.is_null() || vlen == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(val, vlen)
    };
    dict.replace(key_slice, val_slice, val_type as u8, ttl_secs)
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
    let dict = match handle(h) {
        Some(hnd) => &hnd.dict,
        None => return NGX_SHARED_NOT_FOUND,
    };
    if key.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = std::slice::from_raw_parts(key, klen);
    dict.delete(key_slice)
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
    let dict = match handle(h) {
        Some(hnd) => &hnd.dict,
        None => return NGX_SHARED_NOT_FOUND,
    };
    if key.is_null() || result.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = std::slice::from_raw_parts(key, klen);
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
    let dict = match handle(h) {
        Some(hnd) => &hnd.dict,
        None => return NGX_SHARED_NOT_FOUND,
    };
    if key.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = std::slice::from_raw_parts(key, klen);
    dict.expire(key_slice, ttl_secs)
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
    let dict = match handle(h) {
        Some(hnd) => &hnd.dict,
        None => return NGX_SHARED_NOT_FOUND,
    };
    if key.is_null() || out_ttl.is_null() {
        return NGX_SHARED_NOT_FOUND;
    }
    let key_slice = std::slice::from_raw_parts(key, klen);
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
