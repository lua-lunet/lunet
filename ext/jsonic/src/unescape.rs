//! JSON string unescaping.
//!
//! `jsonic::JsonItem::as_str()` returns the raw source slice for a JSON
//! string with the surrounding quotes stripped, but escape sequences are
//! left untouched (verified empirically: `"line1\nline2"` round-trips as
//! the 12-byte literal `line1\nline2`, not an 11-byte string with a real
//! newline). This module turns that raw content into the actual decoded
//! string value, per RFC 8259 §7.

/// Decode a raw (quote-stripped, escape-untouched) JSON string body into its
/// actual value. Returns `Err(message)` on malformed escapes.
pub fn unescape_json_string(raw: &str) -> Result<String, String> {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();

    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            None => return Err("trailing backslash in string".to_string()),
            Some('"') => out.push('"'),
            Some('\\') => out.push('\\'),
            Some('/') => out.push('/'),
            Some('b') => out.push('\u{0008}'),
            Some('f') => out.push('\u{000C}'),
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('u') => {
                let hi = read_hex4(&mut chars)?;
                if (0xD800..=0xDBFF).contains(&hi) {
                    // High surrogate: must be followed by \uDCxx-\uDFxx.
                    if chars.next() != Some('\\') || chars.next() != Some('u') {
                        return Err("unpaired UTF-16 surrogate".to_string());
                    }
                    let lo = read_hex4(&mut chars)?;
                    if !(0xDC00..=0xDFFF).contains(&lo) {
                        return Err("invalid low surrogate".to_string());
                    }
                    let c = 0x10000
                        + (((hi as u32) - 0xD800) << 10)
                        + ((lo as u32) - 0xDC00);
                    match char::from_u32(c) {
                        Some(ch) => out.push(ch),
                        None => return Err("invalid surrogate pair".to_string()),
                    }
                } else if (0xDC00..=0xDFFF).contains(&hi) {
                    return Err("unpaired UTF-16 surrogate".to_string());
                } else {
                    match char::from_u32(hi as u32) {
                        Some(ch) => out.push(ch),
                        None => return Err("invalid \\u escape".to_string()),
                    }
                }
            }
            Some(other) => return Err(format!("invalid escape '\\{other}'")),
        }
    }
    Ok(out)
}

fn read_hex4(chars: &mut std::iter::Peekable<std::str::Chars>) -> Result<u16, String> {
    let mut v: u16 = 0;
    for _ in 0..4 {
        let c = chars.next().ok_or_else(|| "truncated \\u escape".to_string())?;
        let d = c.to_digit(16).ok_or_else(|| "invalid hex digit in \\u escape".to_string())?;
        v = v * 16 + d as u16;
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_plain_string() {
        assert_eq!(unescape_json_string("hello").unwrap(), "hello");
    }

    #[test]
    fn test_empty_string() {
        assert_eq!(unescape_json_string("").unwrap(), "");
    }

    #[test]
    fn test_simple_escapes() {
        assert_eq!(unescape_json_string(r#"quo\"te"#).unwrap(), "quo\"te");
        assert_eq!(unescape_json_string(r"back\\slash").unwrap(), "back\\slash");
        assert_eq!(unescape_json_string(r"forward\/slash").unwrap(), "forward/slash");
        assert_eq!(unescape_json_string(r"line1\nline2").unwrap(), "line1\nline2");
        assert_eq!(unescape_json_string(r"tab\there").unwrap(), "tab\there");
        assert_eq!(unescape_json_string(r"cr\rlf").unwrap(), "cr\rlf");
        assert_eq!(unescape_json_string(r"back\bspace").unwrap(), "back\u{0008}space");
        assert_eq!(unescape_json_string(r"form\ffeed").unwrap(), "form\u{000C}feed");
    }

    #[test]
    fn test_unicode_bmp_escape() {
        // \u00e9 = é
        assert_eq!(unescape_json_string(r"caf\u00e9").unwrap(), "café");
    }

    #[test]
    fn test_unicode_surrogate_pair() {
        // U+1F600 (grinning face emoji) = surrogate pair D83D DE00
        assert_eq!(unescape_json_string(r"\ud83d\ude00").unwrap(), "\u{1F600}");
    }

    #[test]
    fn test_trailing_backslash_rejected() {
        assert!(unescape_json_string("abc\\").is_err());
    }

    #[test]
    fn test_invalid_escape_rejected() {
        assert!(unescape_json_string(r"\q").is_err());
    }

    #[test]
    fn test_truncated_unicode_escape_rejected() {
        assert!(unescape_json_string(r"\u12").is_err());
    }

    #[test]
    fn test_invalid_hex_digit_rejected() {
        assert!(unescape_json_string(r"\u12zz").is_err());
    }

    #[test]
    fn test_unpaired_high_surrogate_rejected() {
        assert!(unescape_json_string(r"\ud83d").is_err());
        assert!(unescape_json_string(r"\ud83dxyz").is_err());
    }

    #[test]
    fn test_unpaired_low_surrogate_rejected() {
        assert!(unescape_json_string(r"\udc00").is_err());
    }

    #[test]
    fn test_high_surrogate_not_followed_by_low_rejected() {
        assert!(unescape_json_string(r"\ud83d\u0041").is_err());
    }

    #[test]
    fn test_mixed_content() {
        assert_eq!(
            unescape_json_string(r#"Hello, \"World\"!\nLine \u00e9nd."#).unwrap(),
            "Hello, \"World\"!\nLine énd."
        );
    }
}
