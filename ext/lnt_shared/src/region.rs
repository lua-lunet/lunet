//! Shared-memory region: `mmap`/`munmap` lifecycle, header layout, and the
//! spinlock that guards all mutations.
//!
//! # Memory layout (offsets from region base)
//!
//! ```text
//! [0 .. HEADER_SIZE)          RegionHeader (one OS page, 4096 bytes)
//! [HEADER_SIZE .. data_offset) HashSlot[hash_capacity]  (16 bytes each)
//! [data_offset .. region_size) Data area (bump allocator)
//! ```
//!
//! All internal references are **offsets from the region base**, never
//! absolute virtual addresses, so the layout is relocatable.
//!
//! # Entry format (in data area)
//!
//! ```text
//! u32  key_len
//! u32  val_len
//! u64  expire_ns   (0 = never expires)
//! u8   val_type    (VTYPE_BYTES=0, VTYPE_F64=1, VTYPE_BOOL=2)
//! u8   flags       (reserved, must be 0)
//! u16  _pad
//! u8   key[key_len]
//! u8   val[val_len]
//! u8   align_pad[] (to next 8-byte boundary)
//! ```

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

use libc::{
    MAP_ANONYMOUS, MAP_FAILED, MAP_SHARED, PROT_READ, PROT_WRITE, mmap, munmap,
};

// ── Constants ───────────────────────────────────────────────────────────────

/// Magic number stored in the header to detect an initialised region.
/// ASCII "NGXSHD_1" in little-endian, retained only for backward compatibility
/// with regions created before the lnt_shared rename.
pub const MAGIC: u64 = 0x315f44485358474e;
pub const VERSION: u32 = 1;
/// The header occupies one OS page so that the hash table that follows it is
/// naturally page-aligned.
pub const HEADER_SIZE: usize = 4096;

/// Size of one hash slot in bytes.
pub const SLOT_SIZE: usize = 16;

/// Sentinel stored in `HashSlot::hash` to indicate an empty (never-used) slot.
pub const SLOT_HASH_EMPTY: u64 = 0;
/// Sentinel stored in `HashSlot::entry_off` to indicate a tombstone (deleted).
pub const SLOT_ENTRY_TOMB: u64 = u64::MAX;

/// Byte size of an entry header (before key/value bytes).
/// key_len(4) + val_len(4) + expire_ns(8) + val_type(1) + flags(1) + pad(2) = 20
pub const ENTRY_HDR_SIZE: usize = 20;

/// Value types stored in `EntryHdr::val_type`.
/// These constants are also used by the Lua FFI wrapper to interpret values.
#[allow(dead_code)]
pub const VTYPE_BYTES: u8 = 0; // raw bytes / string
pub const VTYPE_F64: u8 = 1; // 64-bit float (8 bytes)
#[allow(dead_code)]
pub const VTYPE_BOOL: u8 = 2; // boolean (1 byte: 0=false, 1=true)

// ── Structures ───────────────────────────────────────────────────────────────

/// The region header lives at offset 0 of the mmap'd region.
///
/// All fields except `lock` must only be accessed while holding the spinlock.
/// The `lock` field itself is manipulated with atomic CAS.
///
/// The struct is `repr(C)` so that the compiler does not reorder fields.
/// Padding is explicit.
#[repr(C)]
pub struct RegionHeader {
    /// Spinlock — 0 = unlocked, 1 = locked.  Must be the first field.
    pub lock: AtomicU32, // offset 0
    pub _pad0: u32,      // offset 4
    pub magic: u64,      // offset 8
    pub version: u32,    // offset 16
    pub page_size: u32,  // offset 20

    pub region_size: u64,  // offset 24
    pub hash_offset: u64,  // offset 32 — offset to first HashSlot
    pub hash_capacity: u32, // offset 40 — number of slots
    pub _pad1: u32,        // offset 44

    pub data_offset: u64,   // offset 48 — offset to data area start
    pub data_size: u64,     // offset 56 — total bytes in data area
    pub alloc_top: AtomicU64, // offset 64 — bytes consumed in data area
    pub entry_count: AtomicU32, // offset 72 — live entries
    pub tombstone_count: AtomicU32, // offset 76 — tombstone slots
                            // [80 .. HEADER_SIZE]: zeros / reserved
}

/// One slot in the open-address hash table.
#[repr(C)]
pub struct HashSlot {
    /// FNV-1a 64-bit hash of the key.  `SLOT_HASH_EMPTY` (0) means unused.
    pub hash: u64,
    /// Offset into the **data area** (i.e. relative to `header.data_offset`).
    /// `SLOT_ENTRY_TOMB` means deleted.
    pub entry_off: u64,
}

/// Fixed-size entry header written at the start of every data-area record.
#[repr(C)]
pub struct EntryHdr {
    pub key_len: u32,
    pub val_len: u32,
    pub expire_ns: u64,
    pub val_type: u8,
    pub flags: u8,
    pub _pad: u16,
}

// ── Region ───────────────────────────────────────────────────────────────────

/// Owns one mmap'd region.  Dropping this value calls `munmap`.
pub struct Region {
    /// Base pointer of the mmap region.
    pub ptr: *mut u8,
    /// Total size in bytes.
    pub size: usize,
}

// SAFETY: We protect all interior mutability with a spinlock.
unsafe impl Send for Region {}
unsafe impl Sync for Region {}

impl Region {
    /// Allocate a new anonymous mmap region of `size` bytes and initialise
    /// the header + hash table.
    ///
    /// Returns `None` if `size` is too small, or if `mmap` fails.
    pub fn new(size: usize) -> Option<Self> {
        // Minimum viable region.
        let min_size = HEADER_SIZE + SLOT_SIZE * 64 + 128;
        if size < min_size {
            return None;
        }

        let ptr = unsafe {
            mmap(
                std::ptr::null_mut(),
                size,
                PROT_READ | PROT_WRITE,
                MAP_SHARED | MAP_ANONYMOUS,
                -1,
                0,
            )
        };
        if ptr == MAP_FAILED {
            return None;
        }

        let mut r = Region {
            ptr: ptr as *mut u8,
            size,
        };
        r.init();
        Some(r)
    }

    /// Compute `hash_capacity` for a given region size.
    ///
    /// We allocate ~1/16 of the region to the hash table, rounded up to the
    /// next power of two, with a minimum of 64 slots.
    pub fn compute_hash_capacity(region_size: usize) -> u32 {
        let raw = (region_size / 256).max(64);
        // next_power_of_two saturates at usize::MAX if already > half of usize
        let cap = raw.next_power_of_two();
        cap as u32
    }

    /// Initialise the header and zero the hash table.
    /// The data area is already zeroed by `mmap(MAP_ANONYMOUS)`.
    fn init(&mut self) {
        let hash_cap = Self::compute_hash_capacity(self.size);
        let hash_offset = HEADER_SIZE as u64;
        let data_offset = hash_offset + (hash_cap as u64) * (SLOT_SIZE as u64);
        let data_size = self.size as u64 - data_offset;

        let h = self.header_mut();
        // AtomicU32/AtomicU64 are repr(transparent) over their inner types, so
        // writing through a raw-pointer write is safe here.
        unsafe {
            std::ptr::write(
                h,
                RegionHeader {
                    lock: AtomicU32::new(0),
                    _pad0: 0,
                    magic: MAGIC,
                    version: VERSION,
                    page_size: 4096,
                    region_size: self.size as u64,
                    hash_offset,
                    hash_capacity: hash_cap,
                    _pad1: 0,
                    data_offset,
                    data_size,
                    alloc_top: AtomicU64::new(0),
                    entry_count: AtomicU32::new(0),
                    tombstone_count: AtomicU32::new(0),
                },
            );
        }
    }

    // ── Header ────────────────────────────────────────────────────────────

    #[inline(always)]
    pub fn header(&self) -> &RegionHeader {
        unsafe { &*(self.ptr as *const RegionHeader) }
    }

    #[inline(always)]
    pub fn header_mut(&self) -> *mut RegionHeader {
        self.ptr as *mut RegionHeader
    }

    // ── Hash slots ────────────────────────────────────────────────────────

    /// Returns a mutable pointer to hash slot `i`.
    ///
    /// SAFETY: `i` must be < `header.hash_capacity`.
    #[inline(always)]
    pub unsafe fn slot_ptr(&self, i: u32) -> *mut HashSlot {
        let h = self.header();
        let base = self.ptr.add(h.hash_offset as usize);
        (base as *mut HashSlot).add(i as usize)
    }

    // ── Data area ─────────────────────────────────────────────────────────

    /// Returns a pointer to the start of the data area.
    #[inline(always)]
    pub fn data_base(&self) -> *mut u8 {
        let off = self.header().data_offset as usize;
        unsafe { self.ptr.add(off) }
    }

    // ── Spinlock ──────────────────────────────────────────────────────────

    /// Acquire the region-wide spinlock.
    ///
    /// This is a simple test-and-test-and-set spinlock using
    /// `Acquire`/`Release` ordering.  Contention only occurs if multiple OS
    /// threads (or forked children) access the same region concurrently.
    /// Inside lunet's single-threaded event loop this never spins.
    #[inline]
    pub fn lock(&self) {
        let lock = &self.header().lock;
        loop {
            if lock
                .compare_exchange_weak(0, 1, Ordering::Acquire, Ordering::Relaxed)
                .is_ok()
            {
                return;
            }
            // Back off: wait until the lock looks free before retrying CAS.
            while lock.load(Ordering::Relaxed) != 0 {
                std::hint::spin_loop();
            }
        }
    }

    /// Release the spinlock.
    #[inline]
    pub fn unlock(&self) {
        self.header().lock.store(0, Ordering::Release);
    }
}

impl Drop for Region {
    fn drop(&mut self) {
        unsafe {
            munmap(self.ptr as *mut libc::c_void, self.size);
        }
    }
}
