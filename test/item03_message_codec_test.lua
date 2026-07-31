#!/usr/bin/env lua
-- Test for Item 03: Message Codec
-- Tests pure Lua codec that parses and formats wire protocol messages

local codec = dofile("examples/advisory_lock_cas/codec.lua")

local pass_count = 0

local function assert_eq(got, expected, msg)
    if got ~= expected then
        io.stderr:write(string.format("FAIL: %s: expected %s, got %s\n",
            msg, tostring(expected), tostring(got)))
        os.exit(1)
    end
    pass_count = pass_count + 1
end

local function assert_nil(val, msg)
    if val ~= nil then
        io.stderr:write(string.format("FAIL: %s: expected nil, got %s\n",
            msg, tostring(val)))
        os.exit(1)
    end
    pass_count = pass_count + 1
end

local function assert_not_nil(val, msg)
    if val == nil then
        io.stderr:write(string.format("FAIL: %s: expected non-nil\n", msg))
        os.exit(1)
    end
    pass_count = pass_count + 1
end

-- 1. Parse GET
local function test_parse_get()
    local msg = codec.parse("GET /locks/42 abc00001")
    assert_not_nil(msg, "parse GET returns table")
    assert_eq(msg.type, "GET", "GET type")
    assert_eq(msg.lock_id, 42, "GET lock_id")
    assert_eq(msg.msg_id, "abc00001", "GET msg_id")
end

-- 2. Parse SET
local function test_parse_set()
    local msg = codec.parse("SET /locks/7 0000000700000000 99 def00002")
    assert_not_nil(msg, "parse SET returns table")
    assert_eq(msg.type, "SET", "SET type")
    assert_eq(msg.lock_id, 7, "SET lock_id")
    assert_eq(msg.token, 0x0000000700000000, "SET token")
    assert_eq(msg.holder, 99, "SET holder")
    assert_eq(msg.msg_id, "def00002", "SET msg_id")
end

-- 3. Parse PEER GET
local function test_parse_peer_get()
    local msg = codec.parse("PEER GET /locks/42 aabbccdd")
    assert_not_nil(msg, "parse PEER GET returns table")
    assert_eq(msg.type, "PEER_GET", "PEER_GET type")
    assert_eq(msg.lock_id, 42, "PEER_GET lock_id")
    assert_eq(msg.msg_id, "aabbccdd", "PEER_GET msg_id")
end

-- 4. Parse PEER SET
local function test_parse_peer_set()
    local msg = codec.parse("PEER SET /locks/42 0000002A0000000F 77 eeff0011")
    assert_not_nil(msg, "parse PEER SET returns table")
    assert_eq(msg.type, "PEER_SET", "PEER_SET type")
    assert_eq(msg.lock_id, 42, "PEER_SET lock_id")
    assert_eq(msg.token, 0x0000002A0000000F, "PEER_SET token")
    assert_eq(msg.holder, 77, "PEER_SET holder")
    assert_eq(msg.msg_id, "eeff0011", "PEER_SET msg_id")
end

-- 5. Parse REPLY OK
local function test_parse_reply_ok()
    local msg = codec.parse("REPLY abc00001 OK 42 0000002A0000002A")
    assert_not_nil(msg, "parse REPLY OK returns table")
    assert_eq(msg.type, "REPLY", "REPLY type")
    assert_eq(msg.status, "OK", "REPLY OK status")
    assert_eq(msg.holder, 42, "REPLY OK holder")
    assert_eq(msg.token, 0x0000002A0000002A, "REPLY OK token")
    assert_eq(msg.msg_id, "abc00001", "REPLY OK msg_id")
end

-- 6. Parse REPLY CONFLICT
local function test_parse_reply_conflict()
    local msg = codec.parse("REPLY abc00001 CONFLICT 99 0000002A00000063")
    assert_not_nil(msg, "parse REPLY CONFLICT returns table")
    assert_eq(msg.type, "REPLY", "REPLY CONFLICT type")
    assert_eq(msg.status, "CONFLICT", "REPLY CONFLICT status")
    assert_eq(msg.holder, 99, "REPLY CONFLICT holder")
end

-- 7. Parse REPLY INVALID and UNAVAILABLE; NOT_FOUND is gone
local function test_parse_reply_bare_statuses()
    local msg = codec.parse("REPLY abc00001 INVALID")
    assert_not_nil(msg, "parse REPLY INVALID returns table")
    assert_eq(msg.type, "REPLY", "REPLY INVALID type")
    assert_eq(msg.status, "INVALID", "REPLY INVALID status")
    local msg2 = codec.parse("REPLY abc00001 UNAVAILABLE")
    assert_not_nil(msg2, "parse REPLY UNAVAILABLE returns table")
    assert_eq(msg2.status, "UNAVAILABLE", "REPLY UNAVAILABLE status")
    local msg3 = codec.parse("REPLY abc00001 NOT_FOUND")
    assert_nil(msg3, "NOT_FOUND no longer parses")
end

-- 8. Parse garbage
local function test_parse_garbage()
    local msg, err = codec.parse("garbage")
    assert_nil(msg, "garbage returns nil")
    assert_not_nil(err, "garbage returns error")
end

-- 9. Parse incomplete GET
local function test_parse_incomplete()
    local msg, err = codec.parse("GET /locks/")
    assert_nil(msg, "incomplete returns nil")
    assert_not_nil(err, "incomplete returns error")
end

-- 10. Parse invalid token
local function test_parse_invalid_token()
    local msg, err = codec.parse("SET /locks/1 nothex0000000000 5 00000000")
    assert_nil(msg, "invalid token returns nil")
    assert_not_nil(err, "invalid token returns error")
end

-- 11. Parse bad status
local function test_parse_bad_status()
    local msg, err = codec.parse("REPLY 00000000 BADSTATUS 1 0000000000000001")
    assert_nil(msg, "bad status returns nil")
    assert_not_nil(err, "bad status returns error")
end

-- 12. format_reply OK
local function test_format_reply_ok()
    local s = codec.format_reply("abc00001", "OK", 42, 0x0000002A0000002A)
    assert_eq(s, "REPLY abc00001 OK 42 0000002a0000002a", "format_reply OK")
end

-- 13. format_reply INVALID / UNAVAILABLE
local function test_format_reply_bare()
    local s = codec.format_reply("abc00001", "INVALID")
    assert_eq(s, "REPLY abc00001 INVALID", "format_reply INVALID")
    local s2 = codec.format_reply("abc00001", "UNAVAILABLE")
    assert_eq(s2, "REPLY abc00001 UNAVAILABLE", "format_reply UNAVAILABLE")
end

-- 13b. u64 token exactness beyond 2^53 (ULL roundtrip)
local function test_token_u64_exact()
    local big = 0xFFFFFFFF00000007ULL -- lock_id max u32, holder 7
    local s = codec.format_reply("abc00001", "OK", 7, big)
    assert_eq(s, "REPLY abc00001 OK 7 ffffffff00000007", "format big u64 token")
    local msg = codec.parse(s)
    assert_not_nil(msg, "parse big u64 token")
    assert_eq(msg.token, big, "big u64 token roundtrips exactly")
end

-- 14. format_peer PEER_SET
local function test_format_peer_set()
    local s = codec.format_peer("PEER_SET", 42, 0x0000002A0000000F, 77, "eeff0011")
    assert_eq(s, "PEER SET /locks/42 0000002a0000000f 77 eeff0011", "format_peer PEER_SET")
end

-- 15. format_peer PEER_GET
local function test_format_peer_get()
    local s = codec.format_peer("PEER_GET", 42, nil, nil, "abcd0001")
    assert_eq(s, "PEER GET /locks/42 abcd0001", "format_peer PEER_GET")
end

-- 16. Roundtrip
local function test_roundtrip()
    local formatted = codec.format_reply("abc00001", "OK", 42, 0x0000002A0000002A)
    local msg = codec.parse(formatted)
    assert_not_nil(msg, "roundtrip parse succeeds")
    assert_eq(msg.type, "REPLY", "roundtrip type")
    assert_eq(msg.status, "OK", "roundtrip status")
    assert_eq(msg.holder, 42, "roundtrip holder")
    assert_eq(msg.msg_id, "abc00001", "roundtrip msg_id")
end

-- 17. Empty string
local function test_parse_empty()
    local msg, err = codec.parse("")
    assert_nil(msg, "empty string returns nil")
    assert_not_nil(err, "empty string returns error")
end

-- 18. Trailing whitespace
local function test_parse_trailing_whitespace()
    local msg = codec.parse("GET /locks/42 abc00001   ")
    assert_not_nil(msg, "trailing whitespace parsed")
    assert_eq(msg.type, "GET", "trailing ws type")
    assert_eq(msg.lock_id, 42, "trailing ws lock_id")
    assert_eq(msg.msg_id, "abc00001", "trailing ws msg_id")
end

-- Run all tests
test_parse_get()
test_parse_set()
test_parse_peer_get()
test_parse_peer_set()
test_parse_reply_ok()
test_parse_reply_conflict()
test_parse_reply_bare_statuses()
test_parse_garbage()
test_parse_incomplete()
test_parse_invalid_token()
test_parse_bad_status()
test_format_reply_ok()
test_format_reply_bare()
test_token_u64_exact()
test_format_peer_set()
test_format_peer_get()
test_roundtrip()
test_parse_empty()
test_parse_trailing_whitespace()

print(string.format("All %d assertions passed", pass_count))
os.exit(0)
