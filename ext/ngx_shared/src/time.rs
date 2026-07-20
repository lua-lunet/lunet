//! Monotonic clock — returns nanoseconds since an arbitrary fixed point.
//!
//! Only Linux and macOS are supported. `clock_gettime(CLOCK_MONOTONIC)` is
//! available on both without any additional libraries.

use libc::{clock_gettime, CLOCK_MONOTONIC};

/// Returns a monotonic timestamp in nanoseconds.
/// The epoch is unspecified — values are only meaningful as deltas or for
/// comparing against other values returned by this function.
pub fn now_ns() -> u64 {
    unsafe {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        // CLOCK_MONOTONIC never fails on Linux/macOS in a valid process.
        clock_gettime(CLOCK_MONOTONIC, &mut ts);
        (ts.tv_sec as u64)
            .saturating_mul(1_000_000_000)
            .saturating_add(ts.tv_nsec as u64)
    }
}

/// Convert a TTL in seconds (f64) to an absolute expiry timestamp in
/// nanoseconds, relative to `now_ns()`.  Returns 0 if `ttl_secs <= 0`,
/// which means "no expiry" in the entry format.
pub fn expiry_from_ttl(ttl_secs: f64) -> u64 {
    if ttl_secs <= 0.0 {
        return 0;
    }
    let delta_ns = (ttl_secs * 1_000_000_000.0) as u64;
    now_ns().saturating_add(delta_ns)
}

/// Returns the remaining TTL in seconds for a given `expire_ns` timestamp.
/// Returns `None` if the entry has no expiry (expire_ns == 0).
/// Returns `Some(0.0)` (or small positive) if the entry has expired.
pub fn remaining_ttl(expire_ns: u64) -> Option<f64> {
    if expire_ns == 0 {
        return None;
    }
    let now = now_ns();
    if expire_ns <= now {
        Some(0.0)
    } else {
        Some((expire_ns - now) as f64 / 1_000_000_000.0)
    }
}

/// Returns true if the entry with the given `expire_ns` has expired.
/// An entry with `expire_ns == 0` never expires.
pub fn is_expired(expire_ns: u64) -> bool {
    expire_ns != 0 && expire_ns <= now_ns()
}
