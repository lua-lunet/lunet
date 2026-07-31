#!/usr/bin/env lua
-- Test for Item 02: Lock Table + CAS
-- Tests pure Lua lock table with CAS semantics

local lock = dofile("examples/advisory_lock_cas/lock.lua")

local function assert_eq(got, expected, msg)
    if got ~= expected then
        io.stderr:write(string.format("FAIL: %s: expected %s, got %s\n",
            msg, tostring(expected), tostring(got)))
        os.exit(1)
    end
end

local function test_new()
    local tbl = lock.new()
    assert_eq(type(tbl), "table", "lock.new() returns a table")
end

local function test_pack_token()
    assert_eq(lock.pack_token(1, 0), 4294967296ULL, "pack_token(1, 0)")
    assert_eq(lock.pack_token(1, 7), 4294967303ULL, "pack_token(1, 7)")
    assert_eq(lock.pack_token(0, 5), 5ULL, "pack_token(0, 5)")
end

local function test_unpack_token()
    local lid, h = lock.unpack_token(4294967303ULL)
    assert_eq(lid, 1, "unpack_token lock_id")
    assert_eq(h, 7, "unpack_token holder")
end

local function test_pack_unpack_roundtrip()
    local cases = {{1, 7}, {0, 0}, {42, 0}, {100, 200}, {4294967295, 4294967295}}
    for _, c in ipairs(cases) do
        local token = lock.pack_token(c[1], c[2])
        local lid, h = lock.unpack_token(token)
        assert_eq(lid, c[1], string.format("roundtrip lock_id for (%d, %d)", c[1], c[2]))
        assert_eq(h, c[2], string.format("roundtrip holder for (%d, %d)", c[1], c[2]))
    end
end

local function test_get_nonexistent()
    local tbl = lock.new()
    local holder, token = lock.get(tbl, 42)
    assert_eq(holder, 0, "get nonexistent holder")
    assert_eq(token, lock.pack_token(42, 0), "get nonexistent token")
end

local function test_cas_nonexistent()
    local tbl = lock.new()
    local expected_token = lock.pack_token(10, 0)
    local ok, new_token = lock.cas(tbl, 10, expected_token, 5)
    assert_eq(ok, true, "CAS on nonexistent succeeds")
    assert_eq(new_token, lock.pack_token(10, 5), "CAS on nonexistent new_token")
    local holder, token = lock.get(tbl, 10)
    assert_eq(holder, 5, "after CAS nonexistent holder")
    assert_eq(token, lock.pack_token(10, 5), "after CAS nonexistent token")
end

local function test_cas_correct_token()
    local tbl = lock.new()
    lock.cas(tbl, 10, lock.pack_token(10, 0), 5)
    local ok, new_token = lock.cas(tbl, 10, lock.pack_token(10, 5), 99)
    assert_eq(ok, true, "CAS with correct token succeeds")
    assert_eq(new_token, lock.pack_token(10, 99), "CAS correct token new_token")
    local holder, token = lock.get(tbl, 10)
    assert_eq(holder, 99, "after CAS correct holder")
    assert_eq(token, lock.pack_token(10, 99), "after CAS correct token")
end

local function test_cas_stale_token()
    local tbl = lock.new()
    lock.cas(tbl, 10, lock.pack_token(10, 0), 5)
    local stale_token = lock.pack_token(10, 0)
    local ok, current_token = lock.cas(tbl, 10, stale_token, 99)
    assert_eq(ok, false, "CAS with stale token fails")
    assert_eq(current_token, lock.pack_token(10, 5), "CAS stale returns current_token")
end

local function test_sequential_cas_different_locks()
    local tbl = lock.new()
    local ok1, t1 = lock.cas(tbl, 1, lock.pack_token(1, 0), 10)
    local ok2, t2 = lock.cas(tbl, 2, lock.pack_token(2, 0), 20)
    assert_eq(ok1, true, "CAS lock 1 succeeds")
    assert_eq(ok2, true, "CAS lock 2 succeeds")
    assert_eq(t1, lock.pack_token(1, 10), "CAS lock 1 token")
    assert_eq(t2, lock.pack_token(2, 20), "CAS lock 2 token")
    local h1, _ = lock.get(tbl, 1)
    local h2, _ = lock.get(tbl, 2)
    assert_eq(h1, 10, "lock 1 holder")
    assert_eq(h2, 20, "lock 2 holder")
end

local function test_get_after_cas()
    local tbl = lock.new()
    lock.cas(tbl, 42, lock.pack_token(42, 0), 77)
    local holder, token = lock.get(tbl, 42)
    assert_eq(holder, 77, "get after CAS holder")
    assert_eq(token, lock.pack_token(42, 77), "get after CAS token")
end

local function test_max_u32_lock_id()
    local tbl = lock.new()
    local maxu32 = 4294967295
    local ok, _ = lock.cas(tbl, maxu32, lock.pack_token(maxu32, 0), 1)
    assert_eq(ok, true, "CAS max u32 lock_id succeeds")
    local holder, token = lock.get(tbl, maxu32)
    assert_eq(holder, 1, "max u32 lock_id holder")
    assert_eq(token, lock.pack_token(maxu32, 1), "max u32 lock_id token")
end

local function test_max_u32_holder()
    local tbl = lock.new()
    local maxu32 = 4294967295
    local ok, _ = lock.cas(tbl, 1, lock.pack_token(1, 0), maxu32)
    assert_eq(ok, true, "CAS max u32 holder succeeds")
    local holder, token = lock.get(tbl, 1)
    assert_eq(holder, maxu32, "max u32 holder")
    assert_eq(token, lock.pack_token(1, maxu32), "max u32 holder token")
end

local function test_cas_release()
    local tbl = lock.new()
    lock.cas(tbl, 5, lock.pack_token(5, 0), 42)
    local ok, new_token = lock.cas(tbl, 5, lock.pack_token(5, 42), 0)
    assert_eq(ok, true, "CAS release succeeds")
    assert_eq(new_token, lock.pack_token(5, 0), "CAS release token")
    local holder, token = lock.get(tbl, 5)
    assert_eq(holder, 0, "after release holder")
    assert_eq(token, lock.pack_token(5, 0), "after release token")
end

test_new()
test_pack_token()
test_unpack_token()
test_pack_unpack_roundtrip()
test_get_nonexistent()
test_cas_nonexistent()
test_cas_correct_token()
test_cas_stale_token()
test_sequential_cas_different_locks()
test_get_after_cas()
test_max_u32_lock_id()
test_max_u32_holder()
test_cas_release()

print("PASS: all lock table + CAS tests passed")
os.exit(0)
