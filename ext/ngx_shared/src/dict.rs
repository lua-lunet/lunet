//! Dictionary CRUD operations.
//!
//! All methods that modify state acquire the region spinlock for their entire
//! operation and release it before returning.  This makes each operation
//! atomic with respect to other threads or forked children accessing the same
//! region.
//!
//! ## Error codes (returned as `i32`)
//!
//! ```text
//! NGX_SHARED_OK         0   success
//! NGX_SHARED_NOT_FOUND -1   key does not exist
//! NGX_SHARED_ERR_EXISTS -2  key already exists (add)
//! NGX_SHARED_ERR_NOMEM  -3  data area full
//! NGX_SHARED_ERR_TYPE   -4  type mismatch (incr on non-numeric)
//! NGX_SHARED_ERR_FULL   -5  hash table full (resize not supported)
//! ```

use crate::region::{
    ENTRY_HDR_SIZE, SLOT_ENTRY_TOMB, SLOT_HASH_EMPTY, SLOT_SIZE, VTYPE_F64, EntryHdr, Region,
};
use crate::time::{expiry_from_ttl, is_expired, now_ns, remaining_ttl};
use std::sync::atomic::Ordering;

// ── Public error codes ────────────────────────────────────────────────────────

pub const NGX_SHARED_OK: i32 = 0;
pub const NGX_SHARED_NOT_FOUND: i32 = -1;
pub const NGX_SHARED_ERR_EXISTS: i32 = -2;
pub const NGX_SHARED_ERR_NOMEM: i32 = -3;
pub const NGX_SHARED_ERR_TYPE: i32 = -4;
pub const NGX_SHARED_ERR_FULL: i32 = -5;

// ── FNV-1a 64-bit hash ────────────────────────────────────────────────────────

#[inline]
fn fnv1a_64(data: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    // Ensure the hash is never zero (zero is the "empty slot" sentinel).
    if h == 0 { 1 } else { h }
}

// ── Low-level entry helpers ────────────────────────────────────────────────────

/// Round `n` up to the next 8-byte boundary.
#[inline]
fn align8(n: usize) -> usize {
    (n + 7) & !7
}

/// Total aligned bytes needed to store an entry with `key_len` and `val_len`.
#[inline]
fn entry_total(key_len: usize, val_len: usize) -> usize {
    align8(ENTRY_HDR_SIZE + key_len + val_len)
}

// ── Dict ─────────────────────────────────────────────────────────────────────

/// A thin wrapper around a `Region` that exposes dictionary operations.
///
/// All public methods are safe to call from multiple threads; they acquire
/// the region spinlock internally.
pub struct Dict {
    pub region: Region,
}

impl Dict {
    pub fn new(size: usize) -> Option<Self> {
        Region::new(size).map(|region| Dict { region })
    }

    // ── Internal helpers ─────────────────────────────────────────────────

    /// Find the index of the slot that contains `key` (hash must match and
    /// the actual key bytes must match).  Also returns the first tombstone
    /// index encountered during the probe (useful for insert after failed
    /// lookup).
    ///
    /// SAFETY: must be called while the spinlock is held.
    unsafe fn find_slot(
        &self,
        key: &[u8],
        hash: u64,
    ) -> (Option<u32>, Option<u32>) // (slot_with_key, first_tombstone)
    {
        let h = self.region.header();
        let cap = h.hash_capacity;
        let start = (hash % cap as u64) as u32;
        let mut first_tomb: Option<u32> = None;

        let mut i = 0u32;
        while i < cap {
            let idx = (start + i) % cap;
            let slot = &*self.region.slot_ptr(idx);

            if slot.hash == SLOT_HASH_EMPTY {
                // Empty slot — key definitely not present.
                return (None, first_tomb);
            }
            if slot.entry_off == SLOT_ENTRY_TOMB {
                if first_tomb.is_none() {
                    first_tomb = Some(idx);
                }
                i += 1;
                continue;
            }
            if slot.hash == hash {
                // Hashes match — verify key bytes.
                let entry_ptr = self.region.data_base().add(slot.entry_off as usize);
                let ehdr = &*(entry_ptr as *const EntryHdr);
                if ehdr.key_len as usize == key.len() {
                    let stored_key = std::slice::from_raw_parts(
                        entry_ptr.add(ENTRY_HDR_SIZE),
                        key.len(),
                    );
                    if stored_key == key {
                        // Check expiry — treat expired entries as absent.
                        if is_expired(ehdr.expire_ns) {
                            // Mark as tombstone and continue probing.
                            (*self.region.slot_ptr(idx)).entry_off = SLOT_ENTRY_TOMB;
                            h.tombstone_count.fetch_add(1, Ordering::Relaxed);
                            h.entry_count.fetch_sub(1, Ordering::Relaxed);
                            if first_tomb.is_none() {
                                first_tomb = Some(idx);
                            }
                            i += 1;
                            continue;
                        }
                        return (Some(idx), first_tomb);
                    }
                }
            }
            i += 1;
        }
        (None, first_tomb)
    }

    /// Find an empty or tombstone slot for inserting a new entry.
    ///
    /// SAFETY: must be called while the spinlock is held.
    unsafe fn find_insert_slot(&self, hash: u64, first_tomb: Option<u32>) -> Option<u32> {
        // Prefer re-using a tombstone to keep probe chains short.
        if let Some(t) = first_tomb {
            return Some(t);
        }
        let h = self.region.header();
        let cap = h.hash_capacity;
        let start = (hash % cap as u64) as u32;

        for i in 0..cap {
            let idx = (start + i) % cap;
            let slot = &*self.region.slot_ptr(idx);
            if slot.hash == SLOT_HASH_EMPTY || slot.entry_off == SLOT_ENTRY_TOMB {
                return Some(idx);
            }
        }
        None
    }

    /// Allocate space in the bump allocator and write an entry.
    ///
    /// Returns the data-area-relative offset on success, or `None` if there
    /// is not enough space.
    ///
    /// SAFETY: must be called while the spinlock is held.
    unsafe fn alloc_entry(
        &self,
        key: &[u8],
        val: &[u8],
        val_type: u8,
        expire_ns: u64,
    ) -> Option<u64> {
        let h = self.region.header();
        let total = entry_total(key.len(), val.len());
        let top = h.alloc_top.load(Ordering::Relaxed);
        if top + total as u64 > h.data_size {
            return None;
        }
        let entry_ptr = self.region.data_base().add(top as usize);
        // Write header.
        std::ptr::write(
            entry_ptr as *mut EntryHdr,
            EntryHdr {
                key_len: key.len() as u32,
                val_len: val.len() as u32,
                expire_ns,
                val_type,
                flags: 0,
                _pad: 0,
            },
        );
        // Write key then value.
        std::ptr::copy_nonoverlapping(key.as_ptr(), entry_ptr.add(ENTRY_HDR_SIZE), key.len());
        std::ptr::copy_nonoverlapping(
            val.as_ptr(),
            entry_ptr.add(ENTRY_HDR_SIZE + key.len()),
            val.len(),
        );
        h.alloc_top.store(top + total as u64, Ordering::Relaxed);
        Some(top)
    }

    // ── Public operations ─────────────────────────────────────────────────

    /// Get the value for `key`.
    ///
    /// On success returns `(val_bytes, val_type)`.  The returned `Vec<u8>` is
    /// heap-allocated and owned by the caller.
    pub fn get(&self, key: &[u8]) -> Result<(Vec<u8>, u8), i32> {
        let hash = fnv1a_64(key);
        self.region.lock();
        let result = unsafe {
            let (slot_idx, _) = self.find_slot(key, hash);
            match slot_idx {
                None => Err(NGX_SHARED_NOT_FOUND),
                Some(idx) => {
                    let slot = &*self.region.slot_ptr(idx);
                    let entry_ptr = self.region.data_base().add(slot.entry_off as usize);
                    let ehdr = &*(entry_ptr as *const EntryHdr);
                    let val_ptr = entry_ptr.add(ENTRY_HDR_SIZE + ehdr.key_len as usize);
                    let val = std::slice::from_raw_parts(val_ptr, ehdr.val_len as usize).to_vec();
                    Ok((val, ehdr.val_type))
                }
            }
        };
        self.region.unlock();
        result
    }

    /// Set `key` to `val` (always overwrites).  `ttl_secs <= 0` means no expiry.
    pub fn set(&self, key: &[u8], val: &[u8], val_type: u8, ttl_secs: f64) -> i32 {
        let hash = fnv1a_64(key);
        let expire_ns = expiry_from_ttl(ttl_secs);
        self.region.lock();
        let rc = unsafe {
            let (slot_idx, first_tomb) = self.find_slot(key, hash);
            if let Some(idx) = slot_idx {
                // Key exists — mark old slot as tombstone and re-insert.
                (*self.region.slot_ptr(idx)).entry_off = SLOT_ENTRY_TOMB;
                self.region
                    .header()
                    .tombstone_count
                    .fetch_add(1, Ordering::Relaxed);
                self.region
                    .header()
                    .entry_count
                    .fetch_sub(1, Ordering::Relaxed);
            }
            // Now find an insert slot (may reuse the tombstone we just made).
            let insert_slot = self.find_insert_slot(hash, if slot_idx.is_some() {
                // The slot we just tombstoned is the preferred re-use target.
                slot_idx
            } else {
                first_tomb
            });
            match insert_slot {
                None => NGX_SHARED_ERR_FULL,
                Some(ins_idx) => {
                    match self.alloc_entry(key, val, val_type, expire_ns) {
                        None => NGX_SHARED_ERR_NOMEM,
                        Some(off) => {
                            let slot = &mut *self.region.slot_ptr(ins_idx);
                            let was_tomb = slot.entry_off == SLOT_ENTRY_TOMB;
                            slot.hash = hash;
                            slot.entry_off = off;
                            self.region
                                .header()
                                .entry_count
                                .fetch_add(1, Ordering::Relaxed);
                            if was_tomb {
                                self.region
                                    .header()
                                    .tombstone_count
                                    .fetch_sub(1, Ordering::Relaxed);
                            }
                            NGX_SHARED_OK
                        }
                    }
                }
            }
        };
        self.region.unlock();
        rc
    }

    /// Add `key` only if it does not already exist.
    pub fn add(&self, key: &[u8], val: &[u8], val_type: u8, ttl_secs: f64) -> i32 {
        let hash = fnv1a_64(key);
        let expire_ns = expiry_from_ttl(ttl_secs);
        self.region.lock();
        let rc = unsafe {
            let (slot_idx, first_tomb) = self.find_slot(key, hash);
            if slot_idx.is_some() {
                NGX_SHARED_ERR_EXISTS
            } else {
                match self.find_insert_slot(hash, first_tomb) {
                    None => NGX_SHARED_ERR_FULL,
                    Some(ins_idx) => match self.alloc_entry(key, val, val_type, expire_ns) {
                        None => NGX_SHARED_ERR_NOMEM,
                        Some(off) => {
                            let slot = &mut *self.region.slot_ptr(ins_idx);
                            let was_tomb = slot.entry_off == SLOT_ENTRY_TOMB;
                            slot.hash = hash;
                            slot.entry_off = off;
                            self.region
                                .header()
                                .entry_count
                                .fetch_add(1, Ordering::Relaxed);
                            if was_tomb {
                                self.region
                                    .header()
                                    .tombstone_count
                                    .fetch_sub(1, Ordering::Relaxed);
                            }
                            NGX_SHARED_OK
                        }
                    },
                }
            }
        };
        self.region.unlock();
        rc
    }

    /// Replace `key` only if it already exists.
    pub fn replace(&self, key: &[u8], val: &[u8], val_type: u8, ttl_secs: f64) -> i32 {
        // Implemented as: check-exists + set.  The lock is held for the whole
        // operation so there is no TOCTOU race.
        let hash = fnv1a_64(key);
        let expire_ns = expiry_from_ttl(ttl_secs);
        self.region.lock();
        let rc = unsafe {
            let (slot_idx, _first_tomb) = self.find_slot(key, hash);
            match slot_idx {
                None => NGX_SHARED_NOT_FOUND,
                Some(idx) => {
                    // Tombstone the old slot.
                    (*self.region.slot_ptr(idx)).entry_off = SLOT_ENTRY_TOMB;
                    self.region
                        .header()
                        .tombstone_count
                        .fetch_add(1, Ordering::Relaxed);
                    self.region
                        .header()
                        .entry_count
                        .fetch_sub(1, Ordering::Relaxed);
                    // Re-insert.
                    let insert_slot = self.find_insert_slot(hash, Some(idx));
                    match insert_slot {
                        None => NGX_SHARED_ERR_FULL,
                        Some(ins_idx) => match self.alloc_entry(key, val, val_type, expire_ns) {
                            None => NGX_SHARED_ERR_NOMEM,
                            Some(off) => {
                                let slot = &mut *self.region.slot_ptr(ins_idx);
                                let was_tomb = slot.entry_off == SLOT_ENTRY_TOMB;
                                slot.hash = hash;
                                slot.entry_off = off;
                                self.region
                                    .header()
                                    .entry_count
                                    .fetch_add(1, Ordering::Relaxed);
                                if was_tomb {
                                    self.region
                                        .header()
                                        .tombstone_count
                                        .fetch_sub(1, Ordering::Relaxed);
                                }
                                NGX_SHARED_OK
                            }
                        },
                    }
                }
            }
        };
        self.region.unlock();
        rc
    }

    /// Delete `key`.  Returns `NGX_SHARED_NOT_FOUND` if the key did not exist.
    pub fn delete(&self, key: &[u8]) -> i32 {
        let hash = fnv1a_64(key);
        self.region.lock();
        let rc = unsafe {
            let (slot_idx, _) = self.find_slot(key, hash);
            match slot_idx {
                None => NGX_SHARED_NOT_FOUND,
                Some(idx) => {
                    (*self.region.slot_ptr(idx)).entry_off = SLOT_ENTRY_TOMB;
                    self.region
                        .header()
                        .tombstone_count
                        .fetch_add(1, Ordering::Relaxed);
                    self.region
                        .header()
                        .entry_count
                        .fetch_sub(1, Ordering::Relaxed);
                    NGX_SHARED_OK
                }
            }
        };
        self.region.unlock();
        rc
    }

    /// Atomically increment a numeric key by `delta`.
    ///
    /// If the key does not exist and `has_init` is true, initialise it to
    /// `init` before adding `delta`.
    ///
    /// On success writes the new value into `*result` and returns `NGX_SHARED_OK`.
    pub fn incr(
        &self,
        key: &[u8],
        delta: f64,
        init: f64,
        has_init: bool,
        ttl_secs: f64,
        result: &mut f64,
    ) -> i32 {
        let hash = fnv1a_64(key);
        self.region.lock();
        let rc = unsafe {
            let (slot_idx, first_tomb) = self.find_slot(key, hash);
            match slot_idx {
                None => {
                    if !has_init {
                        NGX_SHARED_NOT_FOUND
                    } else {
                        let new_val = init + delta;
                        let val_bytes = new_val.to_le_bytes();
                        let expire_ns = expiry_from_ttl(ttl_secs);
                        match self.find_insert_slot(hash, first_tomb) {
                            None => NGX_SHARED_ERR_FULL,
                            Some(ins_idx) => {
                                match self.alloc_entry(key, &val_bytes, VTYPE_F64, expire_ns) {
                                    None => NGX_SHARED_ERR_NOMEM,
                                    Some(off) => {
                                        let slot = &mut *self.region.slot_ptr(ins_idx);
                                        let was_tomb = slot.entry_off == SLOT_ENTRY_TOMB;
                                        slot.hash = hash;
                                        slot.entry_off = off;
                                        self.region
                                            .header()
                                            .entry_count
                                            .fetch_add(1, Ordering::Relaxed);
                                        if was_tomb {
                                            self.region
                                                .header()
                                                .tombstone_count
                                                .fetch_sub(1, Ordering::Relaxed);
                                        }
                                        *result = new_val;
                                        NGX_SHARED_OK
                                    }
                                }
                            }
                        }
                    }
                }
                Some(idx) => {
                    // Read current value.
                    let slot = &*self.region.slot_ptr(idx);
                    let entry_ptr = self.region.data_base().add(slot.entry_off as usize);
                    let ehdr = &*(entry_ptr as *const EntryHdr);

                    if ehdr.val_type != VTYPE_F64 {
                        NGX_SHARED_ERR_TYPE
                    } else if ehdr.val_len < 8 {
                        NGX_SHARED_ERR_TYPE
                    } else {
                        let val_ptr = entry_ptr.add(ENTRY_HDR_SIZE + ehdr.key_len as usize);
                        let mut bytes = [0u8; 8];
                        std::ptr::copy_nonoverlapping(val_ptr, bytes.as_mut_ptr(), 8);
                        let current = f64::from_le_bytes(bytes);
                        let new_val = current + delta;
                        let new_bytes = new_val.to_le_bytes();

                        // Preserve expiry if no new TTL given.
                        let expire_ns = if ttl_secs > 0.0 {
                            expiry_from_ttl(ttl_secs)
                        } else {
                            ehdr.expire_ns
                        };

                        // Tombstone old slot and re-insert with updated value.
                        (*self.region.slot_ptr(idx)).entry_off = SLOT_ENTRY_TOMB;
                        self.region
                            .header()
                            .tombstone_count
                            .fetch_add(1, Ordering::Relaxed);
                        self.region
                            .header()
                            .entry_count
                            .fetch_sub(1, Ordering::Relaxed);

                        match self.find_insert_slot(hash, Some(idx)) {
                            None => NGX_SHARED_ERR_FULL,
                            Some(ins_idx) => {
                                match self.alloc_entry(key, &new_bytes, VTYPE_F64, expire_ns) {
                                    None => NGX_SHARED_ERR_NOMEM,
                                    Some(off) => {
                                        let s = &mut *self.region.slot_ptr(ins_idx);
                                        let was_tomb = s.entry_off == SLOT_ENTRY_TOMB;
                                        s.hash = hash;
                                        s.entry_off = off;
                                        self.region
                                            .header()
                                            .entry_count
                                            .fetch_add(1, Ordering::Relaxed);
                                        if was_tomb {
                                            self.region
                                                .header()
                                                .tombstone_count
                                                .fetch_sub(1, Ordering::Relaxed);
                                        }
                                        *result = new_val;
                                        NGX_SHARED_OK
                                    }
                                }
                            }
                        }
                    }
                }
            }
        };
        self.region.unlock();
        rc
    }

    /// Update the TTL of an existing key.  `ttl_secs <= 0` removes expiry.
    pub fn expire(&self, key: &[u8], ttl_secs: f64) -> i32 {
        let hash = fnv1a_64(key);
        self.region.lock();
        let rc = unsafe {
            let (slot_idx, _) = self.find_slot(key, hash);
            match slot_idx {
                None => NGX_SHARED_NOT_FOUND,
                Some(idx) => {
                    let slot = &*self.region.slot_ptr(idx);
                    let entry_ptr = self.region.data_base().add(slot.entry_off as usize);
                    let ehdr = &mut *(entry_ptr as *mut EntryHdr);
                    ehdr.expire_ns = expiry_from_ttl(ttl_secs);
                    NGX_SHARED_OK
                }
            }
        };
        self.region.unlock();
        rc
    }

    /// Get remaining TTL in seconds for `key`.
    ///
    /// Returns `Ok(None)` if the key exists but has no expiry.
    /// Returns `Ok(Some(secs))` if the key exists and has an expiry.
    /// Returns `Err(NGX_SHARED_NOT_FOUND)` if the key does not exist.
    pub fn ttl(&self, key: &[u8]) -> Result<Option<f64>, i32> {
        let hash = fnv1a_64(key);
        self.region.lock();
        let result = unsafe {
            let (slot_idx, _) = self.find_slot(key, hash);
            match slot_idx {
                None => Err(NGX_SHARED_NOT_FOUND),
                Some(idx) => {
                    let slot = &*self.region.slot_ptr(idx);
                    let entry_ptr = self.region.data_base().add(slot.entry_off as usize);
                    let ehdr = &*(entry_ptr as *const EntryHdr);
                    Ok(remaining_ttl(ehdr.expire_ns))
                }
            }
        };
        self.region.unlock();
        result
    }

    /// Clear all entries in the dictionary and reset the bump allocator.
    pub fn flush_all(&self) {
        self.region.lock();
        unsafe {
            let h = self.region.header();
            let cap = h.hash_capacity;
            // Zero all hash slots.
            let slots_ptr = self.region.slot_ptr(0);
            std::ptr::write_bytes(slots_ptr as *mut u8, 0, cap as usize * SLOT_SIZE);
            h.alloc_top.store(0, Ordering::Relaxed);
            h.entry_count.store(0, Ordering::Relaxed);
            h.tombstone_count.store(0, Ordering::Relaxed);
        }
        self.region.unlock();
    }

    /// Scan all hash slots and tombstone any expired entries.
    ///
    /// If `max > 0`, stop after flushing `max` entries.  Returns the number
    /// of entries that were expired.
    pub fn flush_expired(&self, max: i32) -> i32 {
        let now = now_ns();
        self.region.lock();
        let flushed = unsafe {
            let h = self.region.header();
            let cap = h.hash_capacity;
            let mut count = 0i32;
            for i in 0..cap {
                if max > 0 && count >= max {
                    break;
                }
                let slot = &mut *self.region.slot_ptr(i);
                if slot.hash == SLOT_HASH_EMPTY || slot.entry_off == SLOT_ENTRY_TOMB {
                    continue;
                }
                let entry_ptr = self.region.data_base().add(slot.entry_off as usize);
                let ehdr = &*(entry_ptr as *const EntryHdr);
                if ehdr.expire_ns != 0 && ehdr.expire_ns <= now {
                    slot.entry_off = SLOT_ENTRY_TOMB;
                    h.tombstone_count.fetch_add(1, Ordering::Relaxed);
                    h.entry_count.fetch_sub(1, Ordering::Relaxed);
                    count += 1;
                }
            }
            count
        };
        self.region.unlock();
        flushed
    }

    // ── Stats ─────────────────────────────────────────────────────────────

    /// Total capacity of the region in bytes.
    pub fn capacity(&self) -> u64 {
        self.region.header().region_size
    }

    /// Approximate free bytes remaining in the data area.
    pub fn free_space(&self) -> u64 {
        let h = self.region.header();
        let used = h.alloc_top.load(Ordering::Relaxed);
        h.data_size.saturating_sub(used)
    }
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn new_dict() -> Dict {
        Dict::new(512 * 1024).expect("mmap failed")
    }

    #[test]
    fn test_set_get_string() {
        let d = new_dict();
        assert_eq!(d.set(b"hello", b"world", 0, 0.0), NGX_SHARED_OK);
        let (val, vtype) = d.get(b"hello").unwrap();
        assert_eq!(val, b"world");
        assert_eq!(vtype, 0);
    }

    #[test]
    fn test_get_not_found() {
        let d = new_dict();
        let e = d.get(b"missing").unwrap_err();
        assert_eq!(e, NGX_SHARED_NOT_FOUND);
    }

    #[test]
    fn test_delete() {
        let d = new_dict();
        d.set(b"k", b"v", 0, 0.0);
        assert_eq!(d.delete(b"k"), NGX_SHARED_OK);
        assert_eq!(d.delete(b"k"), NGX_SHARED_NOT_FOUND);
        assert!(d.get(b"k").is_err());
    }

    #[test]
    fn test_add_reject_duplicate() {
        let d = new_dict();
        assert_eq!(d.add(b"k", b"first", 0, 0.0), NGX_SHARED_OK);
        assert_eq!(d.add(b"k", b"second", 0, 0.0), NGX_SHARED_ERR_EXISTS);
        let (val, _) = d.get(b"k").unwrap();
        assert_eq!(val, b"first");
    }

    #[test]
    fn test_replace_existing() {
        let d = new_dict();
        assert_eq!(d.replace(b"k", b"v", 0, 0.0), NGX_SHARED_NOT_FOUND);
        d.set(b"k", b"v1", 0, 0.0);
        assert_eq!(d.replace(b"k", b"v2", 0, 0.0), NGX_SHARED_OK);
        let (val, _) = d.get(b"k").unwrap();
        assert_eq!(val, b"v2");
    }

    #[test]
    fn test_incr_with_init() {
        let d = new_dict();
        let mut result = 0.0f64;
        // Key absent, init=0 -> result=1
        assert_eq!(d.incr(b"ctr", 1.0, 0.0, true, 0.0, &mut result), NGX_SHARED_OK);
        assert_eq!(result, 1.0);
        // Key present, increment again -> result=6
        assert_eq!(d.incr(b"ctr", 5.0, 0.0, true, 0.0, &mut result), NGX_SHARED_OK);
        assert_eq!(result, 6.0);
    }

    #[test]
    fn test_incr_no_init_returns_not_found() {
        let d = new_dict();
        let mut result = 0.0f64;
        assert_eq!(d.incr(b"missing", 1.0, 0.0, false, 0.0, &mut result), NGX_SHARED_NOT_FOUND);
    }

    #[test]
    fn test_incr_type_mismatch() {
        let d = new_dict();
        d.set(b"str_key", b"hello", 0, 0.0);
        let mut result = 0.0f64;
        assert_eq!(d.incr(b"str_key", 1.0, 0.0, false, 0.0, &mut result), NGX_SHARED_ERR_TYPE);
    }

    #[test]
    fn test_flush_all() {
        let d = new_dict();
        d.set(b"a", b"1", 0, 0.0);
        d.set(b"b", b"2", 0, 0.0);
        d.flush_all();
        assert!(d.get(b"a").is_err());
        assert!(d.get(b"b").is_err());
        // Should be able to set again after flush
        assert_eq!(d.set(b"a", b"new", 0, 0.0), NGX_SHARED_OK);
        let (val, _) = d.get(b"a").unwrap();
        assert_eq!(val, b"new");
    }

    #[test]
    fn test_overwrite_same_key() {
        let d = new_dict();
        d.set(b"k", b"v1", 0, 0.0);
        d.set(b"k", b"v2", 0, 0.0);
        d.set(b"k", b"v3", 0, 0.0);
        let (val, _) = d.get(b"k").unwrap();
        assert_eq!(val, b"v3");
    }

    #[test]
    fn test_ttl_set_and_get() {
        let d = new_dict();
        d.set(b"k", b"v", 0, 10.0); // 10 seconds TTL
        let ttl = d.ttl(b"k").unwrap();
        // Should be Some(secs) where 0 < secs <= 10
        let secs = ttl.unwrap();
        assert!(secs > 0.0 && secs <= 10.0, "ttl={}", secs);
    }

    #[test]
    fn test_ttl_no_expiry() {
        let d = new_dict();
        d.set(b"k", b"v", 0, 0.0); // no TTL
        let ttl = d.ttl(b"k").unwrap();
        assert!(ttl.is_none()); // None = no expiry
    }

    #[test]
    fn test_expire_removes_ttl() {
        let d = new_dict();
        d.set(b"k", b"v", 0, 10.0);
        d.expire(b"k", 0.0); // remove expiry
        let ttl = d.ttl(b"k").unwrap();
        assert!(ttl.is_none());
    }

    #[test]
    fn test_capacity_and_free_space() {
        let d = new_dict();
        let cap = d.capacity();
        let free = d.free_space();
        assert!(cap >= 512 * 1024);
        assert!(free > 0 && free <= cap);
    }

    #[test]
    fn test_many_keys() {
        let d = new_dict();
        // Insert 200 distinct keys and read them back.
        for i in 0..200u32 {
            let k = format!("key_{i}");
            let v = format!("value_{i}");
            assert_eq!(d.set(k.as_bytes(), v.as_bytes(), 0, 0.0), NGX_SHARED_OK, "set {k}");
        }
        for i in 0..200u32 {
            let k = format!("key_{i}");
            let expected = format!("value_{i}");
            let (val, _) = d
                .get(k.as_bytes())
                .unwrap_or_else(|_| panic!("get {k} failed"));
            assert_eq!(val, expected.as_bytes());
        }
    }
}
