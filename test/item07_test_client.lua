#!/usr/bin/env lua
-- Test Client for Item 07: Concurrent SET Verification

local lunet = require("lunet")
local udp = require("lunet.udp")

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local config_path = ".tmp/advisory_lock_config.lua"

local config = dofile(config_path)
if type(config) ~= "table" then
    io.stderr:write("FAIL: cannot load config\n")
    os.exit(1)
end

local codec = dofile(script_dir .. "/../examples/advisory_lock_cas/codec.lua")

local hi_client_port = config.n1.client_port
local lo_client_port = config.n2.client_port
local host = "127.0.0.1"

local checks_passed = 0
local checks_failed = 0

local function check(name, cond, msg)
    if cond then
        checks_passed = checks_passed + 1
        print("[test] " .. name .. " PASS")
    else
        checks_failed = checks_failed + 1
        io.stderr:write("[test] " .. name .. " FAIL: " .. msg .. "\n")
    end
end

local function send_recv(sock, target_host, target_port, msg)
    local ok, err = udp.send(sock, target_host, target_port, msg)
    if not ok then
        io.stderr:write("FAIL: send error: " .. tostring(err) .. "\n")
        return nil
    end
    local data, _, _ = udp.recv(sock)
    if not data then
        io.stderr:write("FAIL: recv returned nil\n")
        return nil
    end
    return codec.parse(data)
end

local function make_msg_id()
    return string.format("%08x", math.random(0, 0xFFFFFFFF))
end

lunet.spawn(function()
    local sock, err = udp.bind(host, 0)
    if not sock then
        io.stderr:write("FAIL: cannot bind client socket: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    -- Test a: GET lock 1 from Hi -> OK holder=0
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/1 %s", msg_id)
        local reply = send_recv(sock, host, hi_client_port, msg)
        check("a: GET lock=1 from Hi",
            reply and reply.type == "REPLY" and reply.status == "OK" and reply.holder == 0,
            string.format("expected OK holder=0, got status=%s holder=%s",
                reply and tostring(reply.status) or "nil",
                reply and tostring(reply.holder) or "nil"))
    end

    -- Test b: SET lock 1 to holder=42 via Hi -> OK
    local set_b_token
    do
        local msg_id = make_msg_id()
        local msg = string.format("SET /locks/1 %016x 42 %s", 0, msg_id)
        local reply = send_recv(sock, host, hi_client_port, msg)
        set_b_token = reply and reply.token
        check("b: SET lock=1 holder=42 via Hi",
            reply and reply.type == "REPLY" and reply.status == "OK" and reply.holder == 42,
            string.format("expected OK holder=42, got status=%s holder=%s",
                reply and tostring(reply.status) or "nil",
                reply and tostring(reply.holder) or "nil"))
    end

    -- Test c: GET lock 1 from Lo -> OK holder=42, token matches
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/1 %s", msg_id)
        local reply = send_recv(sock, host, lo_client_port, msg)
        local token_ok = set_b_token and reply and reply.token == set_b_token
        check("c: GET lock=1 from Lo",
            reply and reply.type == "REPLY" and reply.status == "OK" and reply.holder == 42 and token_ok,
            string.format("expected OK holder=42 token match, got status=%s holder=%s token=%s",
                reply and tostring(reply.status) or "nil",
                reply and tostring(reply.holder) or "nil",
                reply and string.format("%016x", reply.token) or "nil"))
    end

    -- Test d: SET lock 1 with stale token via Hi -> CONFLICT holder=42
    do
        local msg_id = make_msg_id()
        local msg = string.format("SET /locks/1 %016x 99 %s", 0, msg_id)
        local reply = send_recv(sock, host, hi_client_port, msg)
        check("d: SET lock=1 stale token via Hi",
            reply and reply.type == "REPLY" and reply.status == "CONFLICT" and reply.holder == 42,
            string.format("expected CONFLICT holder=42, got status=%s holder=%s",
                reply and tostring(reply.status) or "nil",
                reply and tostring(reply.holder) or "nil"))
    end

    -- Concurrent test: lock 2, both nodes, two competing SETs released
    -- together on a barrier (BUG-2: no serializing sleep).
    local results = {}
    local done_count = 0
    local ready_count = 0
    local release = false

    local sock_a, sa_err = udp.bind(host, 0)
    if not sock_a then
        io.stderr:write("FAIL: cannot bind sock_a: " .. tostring(sa_err) .. "\n")
        os.exit(1)
    end

    local sock_b, sb_err = udp.bind(host, 0)
    if not sock_b then
        io.stderr:write("FAIL: cannot bind sock_b: " .. tostring(sb_err) .. "\n")
        os.exit(1)
    end

    local unheld_token = 2 * 0x100000000

    lunet.spawn(function()
        local msg_id = make_msg_id()
        local msg = string.format("SET /locks/2 %016x 100 %s", unheld_token, msg_id)
        ready_count = ready_count + 1
        while not release do lunet.sleep(0) end
        local reply = send_recv(sock_a, host, hi_client_port, msg)
        results.a = reply
        done_count = done_count + 1
    end)

    lunet.spawn(function()
        local msg_id = make_msg_id()
        local msg = string.format("SET /locks/2 %016x 200 %s", unheld_token, msg_id)
        ready_count = ready_count + 1
        while not release do lunet.sleep(0) end
        local reply = send_recv(sock_b, host, lo_client_port, msg)
        results.b = reply
        done_count = done_count + 1
    end)

    while ready_count < 2 do lunet.sleep(0) end
    release = true

    local wait_limit = 100
    local waited = 0
    while done_count < 2 and waited < wait_limit do
        lunet.sleep(100)
        waited = waited + 1
    end

    -- Test g: exactly one OK, exactly one CONFLICT
    local a_ok = results.a and results.a.status == "OK"
    local b_ok = results.b and results.b.status == "OK"
    local a_conflict = results.a and results.a.status == "CONFLICT"
    local b_conflict = results.b and results.b.status == "CONFLICT"

    check("g: exactly one OK and one CONFLICT",
        (a_ok and b_conflict) or (b_ok and a_conflict),
        string.format("a.status=%s b.status=%s",
            results.a and tostring(results.a.status) or "nil",
            results.b and tostring(results.b.status) or "nil"))

    -- Test h: loser's CONFLICT shows winner's holder
    local winner_holder
    if a_ok then
        winner_holder = 100
    else
        winner_holder = 200
    end

    local loser_reply = a_ok and results.b or results.a
    check("h: loser CONFLICT shows winner's holder",
        loser_reply and loser_reply.status == "CONFLICT" and loser_reply.holder == winner_holder,
        string.format("expected CONFLICT holder=%d, got status=%s holder=%s",
            winner_holder,
            loser_reply and tostring(loser_reply.status) or "nil",
            loser_reply and tostring(loser_reply.holder) or "nil"))

    local winner_reply = a_ok and results.a or results.b
    local winner_token = winner_reply and winner_reply.token

    -- Test i: GET lock 2 from Hi -> holder matches winner
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/2 %s", msg_id)
        local reply = send_recv(sock, host, hi_client_port, msg)
        check("i: GET lock=2 from Hi matches winner",
            reply and reply.type == "REPLY" and reply.status == "OK" and reply.holder == winner_holder,
            string.format("expected OK holder=%d, got status=%s holder=%s",
                winner_holder,
                reply and tostring(reply.status) or "nil",
                reply and tostring(reply.holder) or "nil"))
    end

    -- Test j: GET lock 2 from Lo -> holder matches winner
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/2 %s", msg_id)
        local reply = send_recv(sock, host, lo_client_port, msg)
        check("j: GET lock=2 from Lo matches winner",
            reply and reply.type == "REPLY" and reply.status == "OK" and reply.holder == winner_holder,
            string.format("expected OK holder=%d, got status=%s holder=%s",
                winner_holder,
                reply and tostring(reply.status) or "nil",
                reply and tostring(reply.holder) or "nil"))
    end

    -- Test k: SET lock 2 with correct token to holder=77 -> OK
    do
        local msg_id = make_msg_id()
        local msg = string.format("SET /locks/2 %016x 77 %s", winner_token, msg_id)
        local reply = send_recv(sock, host, hi_client_port, msg)
        check("k: SET lock=2 holder=77 via Hi",
            reply and reply.type == "REPLY" and reply.status == "OK" and reply.holder == 77,
            string.format("expected OK holder=77, got status=%s holder=%s",
                reply and tostring(reply.status) or "nil",
                reply and tostring(reply.holder) or "nil"))
    end

    -- Test l: GET lock 2 from both nodes -> holder=77
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/2 %s", msg_id)
        local reply_hi = send_recv(sock, host, hi_client_port, msg)
        check("l1: GET lock=2 from Hi -> holder=77",
            reply_hi and reply_hi.type == "REPLY" and reply_hi.status == "OK" and reply_hi.holder == 77,
            string.format("expected OK holder=77, got status=%s holder=%s",
                reply_hi and tostring(reply_hi.status) or "nil",
                reply_hi and tostring(reply_hi.holder) or "nil"))
    end
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/2 %s", msg_id)
        local reply_lo = send_recv(sock, host, lo_client_port, msg)
        check("l2: GET lock=2 from Lo -> holder=77",
            reply_lo and reply_lo.type == "REPLY" and reply_lo.status == "OK" and reply_lo.holder == 77,
            string.format("expected OK holder=77, got status=%s holder=%s",
                reply_lo and tostring(reply_lo.status) or "nil",
                reply_lo and tostring(reply_lo.holder) or "nil"))
    end

    udp.close(sock_a)
    udp.close(sock_b)
    udp.close(sock)

    if checks_failed > 0 then
        io.stderr:write("FAIL: " .. checks_failed .. " check(s) failed\n")
        os.exit(1)
    end

    print("=== concurrent advisory lock CAS: all " .. checks_passed .. " checks passed ===")
    os.exit(0)
end)
