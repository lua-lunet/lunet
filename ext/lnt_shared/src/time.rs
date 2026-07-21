//! Monotonic clock — nanoseconds since process start.
//!
//! Uses `std::time::Instant` (CLOCK_MONOTONIC on Linux, mach continuous time
//! on macOS), so no unsafe code and no extra dependencies.  Values are only
//! ever compared against other values from this process — the mmap region is
//! anonymous and never persists across processes — so a process-relative
//! epoch is sufficient.

use std::sync::OnceLock;
use std::time::Instant;

/// Process-lifetime epoch for monotonic timestamps.
fn epoch() -> &'static Instant {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    EPOCH.get_or_init(Instant::now)
}

/// Returns a monotonic timestamp in nanoseconds relative to process start.
/// Values are only meaningful as deltas or for comparing against other
/// values returned by this function.
pub fn now_ns() -> u64 {
    // u128 -> u64 wraps after ~584 years of uptime; not a concern here.
    epoch().elapsed().as_nanos() as u64
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_now_ns_monotonic_non_decreasing() {
        let mut prev = now_ns();
        for _ in 0..1000 {
            let cur = now_ns();
            assert!(cur >= prev, "clock went backwards: {cur} < {prev}");
            prev = cur;
        }
    }

    #[test]
    fn test_expiry_from_ttl_non_positive_is_never() {
        assert_eq!(expiry_from_ttl(0.0), 0);
        assert_eq!(expiry_from_ttl(-1.0), 0);
        assert_eq!(expiry_from_ttl(-999.5), 0);
    }

    #[test]
    fn test_expiry_from_ttl_positive_is_future() {
        let before = now_ns();
        let exp = expiry_from_ttl(1.0);
        let after = now_ns();
        assert!(exp >= before + 1_000_000_000, "exp={exp} before={before}");
        assert!(exp <= after + 1_000_000_000, "exp={exp} after={after}");
    }

    #[test]
    fn test_remaining_ttl_none_when_no_expiry() {
        assert_eq!(remaining_ttl(0), None);
    }

    #[test]
    fn test_remaining_ttl_expired_is_zero() {
        let past = now_ns() - 1_000_000;
        assert_eq!(remaining_ttl(past), Some(0.0));
    }

    #[test]
    fn test_remaining_ttl_future() {
        let fut = expiry_from_ttl(10.0);
        let rem = remaining_ttl(fut).unwrap();
        assert!(rem > 0.0 && rem <= 10.0, "rem={rem}");
    }

    #[test]
    fn test_is_expired() {
        assert!(!is_expired(0)); // 0 = never expires
        assert!(!is_expired(u64::MAX));
        assert!(is_expired(1)); // 1 ns after epoch — long past
        assert!(is_expired(now_ns())); // boundary: now counts as expired
    }
}
