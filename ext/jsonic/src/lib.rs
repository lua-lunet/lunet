//! # lunet-jsonic
//!
//! Thin LuaJIT FFI wrapper around [`jsonic`](https://github.com/g1mv/jsonic).
//! The Rust side parses JSON and emits a flat tagged buffer; the Lua side
//! reads that buffer linearly and exposes dkjson-style `encode`/`decode`/
//! `null`.

#![allow(unsafe_op_in_unsafe_fn)]

mod unescape;

use jsonic::json_item::JsonItem;
use jsonic::json_type::JsonType;
use std::convert::TryFrom;
use std::os::raw::c_int;
use std::panic::{self, AssertUnwindSafe};

pub const JSONIC_OK: i32 = 0;
pub const JSONIC_ERR_PARSE: i32 = -1;
pub const JSONIC_ERR_INVAL: i32 = -2;

#[repr(u8)]
enum Tag {
    Null = 0,
    False = 1,
    True = 2,
    Number = 3,
    String = 4,
    Array = 5,
    Object = 6,
}

#[inline]
fn guard<R>(on_panic: R, f: impl FnOnce() -> R) -> R {
    panic::catch_unwind(AssertUnwindSafe(f)).unwrap_or(on_panic)
}

unsafe fn write_bytes(out: *mut *mut u8, out_len: *mut usize, bytes: Vec<u8>) -> c_int {
    if out.is_null() || out_len.is_null() {
        return JSONIC_ERR_INVAL;
    }
    let boxed = bytes.into_boxed_slice();
    *out_len = boxed.len();
    *out = Box::into_raw(boxed) as *mut u8;
    JSONIC_OK
}

unsafe fn write_err(out: *mut *mut u8, out_len: *mut usize, msg: &str) {
    if out.is_null() || out_len.is_null() {
        return;
    }
    let _ = write_bytes(out, out_len, msg.as_bytes().to_vec());
}

/// Parse `json` and emit the flat tagged buffer consumed by `jsonic.lua`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lunet_jsonic_decode(
    json: *const u8,
    len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guard(JSONIC_ERR_INVAL, || {
        if json.is_null() || out.is_null() || out_len.is_null() {
            return JSONIC_ERR_INVAL;
        }

        let bytes = std::slice::from_raw_parts(json, len);
        let text = match std::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(_) => {
                write_err(out, out_len, "input is not valid UTF-8");
                return JSONIC_ERR_PARSE;
            }
        };

        let parsed = match jsonic::parse(text) {
            Ok(item) => item,
            Err(err) => {
                write_err(out, out_len, &err.to_string());
                return JSONIC_ERR_PARSE;
            }
        };

        let mut buf = Vec::new();
        if let Err(err) = emit(&parsed, &mut buf) {
            write_err(out, out_len, &err);
            return JSONIC_ERR_PARSE;
        }

        write_bytes(out, out_len, buf)
    })
}

/// Free a buffer returned by [`lunet_jsonic_decode`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lunet_jsonic_free_bytes(p: *mut u8, len: usize) {
    guard((), || {
        if !p.is_null() {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)));
        }
    })
}

fn push_u8(buf: &mut Vec<u8>, v: u8) {
    buf.push(v);
}

fn push_u32(buf: &mut Vec<u8>, v: usize) -> Result<(), String> {
    let v = u32::try_from(v).map_err(|_| "value too large for jsonic buffer".to_string())?;
    buf.extend_from_slice(&v.to_le_bytes());
    Ok(())
}

fn push_f64(buf: &mut Vec<u8>, v: f64) {
    buf.extend_from_slice(&v.to_le_bytes());
}

fn push_str(buf: &mut Vec<u8>, s: &str) -> Result<(), String> {
    push_u8(buf, Tag::String as u8);
    push_u32(buf, s.len())?;
    buf.extend_from_slice(s.as_bytes());
    Ok(())
}

fn emit(item: &JsonItem, buf: &mut Vec<u8>) -> Result<(), String> {
    match item.get_type() {
        JsonType::JsonNull => {
            push_u8(buf, Tag::Null as u8);
            Ok(())
        }
        JsonType::JsonTrue => {
            push_u8(buf, Tag::True as u8);
            Ok(())
        }
        JsonType::JsonFalse => {
            push_u8(buf, Tag::False as u8);
            Ok(())
        }
        JsonType::JsonNumber => {
            let n = item.as_f64().ok_or_else(|| "malformed JSON number".to_string())?;
            push_u8(buf, Tag::Number as u8);
            push_f64(buf, n);
            Ok(())
        }
        JsonType::JsonString => {
            let raw = item.as_str().unwrap_or("");
            let s = unescape::unescape_json_string(raw)?;
            push_str(buf, &s)
        }
        JsonType::JsonArray => {
            let mut children = Vec::new();
            if let Some(iter) = item.elements() {
                for child in iter {
                    children.push(child);
                }
            }
            push_u8(buf, Tag::Array as u8);
            push_u32(buf, children.len())?;
            for child in children {
                emit(child, buf)?;
            }
            Ok(())
        }
        JsonType::JsonMap => {
            let mut entries = Vec::new();
            if let Some(iter) = item.entries() {
                for (k, v) in iter {
                    entries.push((k, v));
                }
            }
            push_u8(buf, Tag::Object as u8);
            push_u32(buf, entries.len())?;
            for (k, v) in entries {
                let key = unescape::unescape_json_string(k.as_str())?;
                push_str(buf, &key)?;
                emit(v, buf)?;
            }
            Ok(())
        }
        JsonType::Empty => Err("unexpected empty JSON item".to_string()),
    }
}

#[cfg(test)]
mod probe {
    #[test]
    fn probe_string_slice_semantics() {
        let json = r#"{"a":"hi","b":"line1\nline2","c":"quo\"te","n":42,"t":true,"nil":null}"#;
        let parsed = jsonic::parse(json).expect("parse failed");

        assert_eq!(parsed["a"].as_str().unwrap(), "hi");
        assert_eq!(parsed["b"].as_str().unwrap(), "line1\\nline2");
        assert_eq!(parsed["c"].as_str().unwrap(), "quo\\\"te");
        assert_eq!(parsed["n"].as_str().unwrap(), "42");
        assert_eq!(parsed["t"].as_str().unwrap(), "true");
        assert_eq!(parsed["nil"].as_str().unwrap(), "null");
    }
}

#[cfg(test)]
mod ffi_tests {
    use super::*;

    fn decode_ok(json: &str) -> (*mut u8, usize) {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = unsafe { lunet_jsonic_decode(json.as_ptr(), json.len(), &mut out, &mut out_len) };
        assert_eq!(rc, JSONIC_OK, "decode should succeed for: {json}");
        (out, out_len)
    }

    fn read_tag(buf: *const u8, pos: &mut usize) -> u8 {
        let tag = unsafe { *buf.add(*pos) };
        *pos += 1;
        tag
    }

    fn read_u32(buf: *const u8, pos: &mut usize) -> u32 {
        let mut bytes = [0u8; 4];
        unsafe {
            std::ptr::copy_nonoverlapping(buf.add(*pos), bytes.as_mut_ptr(), 4);
        }
        *pos += 4;
        u32::from_le_bytes(bytes)
    }

    fn read_f64(buf: *const u8, pos: &mut usize) -> f64 {
        let mut bytes = [0u8; 8];
        unsafe {
            std::ptr::copy_nonoverlapping(buf.add(*pos), bytes.as_mut_ptr(), 8);
        }
        *pos += 8;
        f64::from_le_bytes(bytes)
    }

    fn read_str(buf: *const u8, pos: &mut usize) -> String {
        let len = read_u32(buf, pos) as usize;
        let mut bytes = vec![0u8; len];
        unsafe {
            std::ptr::copy_nonoverlapping(buf.add(*pos), bytes.as_mut_ptr(), len);
        }
        *pos += len;
        String::from_utf8(bytes).unwrap()
    }

    #[derive(Debug, PartialEq)]
    enum Value {
        Null,
        Bool(bool),
        Number(f64),
        String(String),
        Array(Vec<Value>),
        Object(Vec<(String, Value)>),
    }

    fn read_value(buf: *const u8, pos: &mut usize) -> Value {
        match read_tag(buf, pos) {
            0 => Value::Null,
            1 => Value::Bool(false),
            2 => Value::Bool(true),
            3 => Value::Number(read_f64(buf, pos)),
            4 => Value::String(read_str(buf, pos)),
            5 => {
                let n = read_u32(buf, pos) as usize;
                let mut arr = Vec::with_capacity(n);
                for _ in 0..n {
                    arr.push(read_value(buf, pos));
                }
                Value::Array(arr)
            }
            6 => {
                let n = read_u32(buf, pos) as usize;
                let mut obj = Vec::with_capacity(n);
                for _ in 0..n {
                    let key = match read_value(buf, pos) {
                        Value::String(key) => key,
                        other => panic!("expected string key, got {other:?}"),
                    };
                    let value = read_value(buf, pos);
                    obj.push((key, value));
                }
                Value::Object(obj)
            }
            other => panic!("unexpected tag {other}"),
        }
    }

    #[test]
    fn test_decode_nested_values() {
        let (ptr, len) = decode_ok(r#"{"name":"lunet","tags":["fast","small"],"meta":{"ok":true}}"#);
        let mut pos = 0;
        let value = read_value(ptr, &mut pos);
        unsafe { lunet_jsonic_free_bytes(ptr, len) };

        match value {
            Value::Object(entries) => {
                assert_eq!(entries.len(), 3);
                assert_eq!(entries[0].0, "name");
                assert_eq!(entries[1].0, "tags");
                assert_eq!(entries[2].0, "meta");
            }
            _ => panic!("expected object"),
        }
        assert_eq!(pos, len);
    }

    #[test]
    fn test_decode_invalid_json_reports_error() {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = unsafe {
            lunet_jsonic_decode(b"{not valid}".as_ptr(), "{not valid}".len(), &mut out, &mut out_len)
        };
        assert_eq!(rc, JSONIC_ERR_PARSE);
        assert!(!out.is_null());
        assert!(out_len > 0);
        unsafe { lunet_jsonic_free_bytes(out, out_len) };
    }

    #[test]
    fn test_decode_invalid_utf8_reports_error() {
        let bytes: &[u8] = &[0x7B, 0xFF, 0xFE, 0x7D];
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = unsafe { lunet_jsonic_decode(bytes.as_ptr(), bytes.len(), &mut out, &mut out_len) };
        assert_eq!(rc, JSONIC_ERR_PARSE);
        assert!(!out.is_null());
        unsafe { lunet_jsonic_free_bytes(out, out_len) };
    }

    #[test]
    fn test_decode_null_args_are_rejected() {
        let rc = unsafe {
            lunet_jsonic_decode(std::ptr::null(), 0, std::ptr::null_mut(), std::ptr::null_mut())
        };
        assert_eq!(rc, JSONIC_ERR_INVAL);
    }
}
