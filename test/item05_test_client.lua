#!/usr/bin/env lua
-- Test Client for Item 05: Node Main Loop
-- Sends GET/SET messages to Hi and Lo nodes and verifies responses

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

local hi_client_port = config.hi.client_port
local lo_client_port = config.lo.client_port
local host = "127.0.0.1"

local function send_recv(sock, target_host, target_port, msg)
    local ok, err = udp.send(sock, target_host, target_port, msg)
    if not ok then
        io.stderr:write("FAIL: send error: " .. tostring(err) .. "\n")
        return nil
    end
    local data, rhost, rport = udp.recv(sock)
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

    local failures = 0

    -- Test a: GET lock 1 from Hi -> OK holder=0
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/1 %s", msg_id)
        print("[test] sending GET lock=1 to Hi")
        local reply = send_recv(sock, host, hi_client_port, msg)
        if not reply then
            io.stderr:write("FAIL: test a: no reply\n")
            failures = failures + 1
        elseif reply.type ~= "REPLY" or reply.status ~= "OK" or reply.holder ~= 0 then
            io.stderr:write(string.format("FAIL: test a: expected OK holder=0, got status=%s holder=%s\n",
                tostring(reply.status), tostring(reply.holder)))
            failures = failures + 1
        else
            print("[test] test a PASS: GET lock=1 from Hi -> OK holder=0")
        end
    end

    -- Test b: SET lock 1 to holder=42 via Hi -> OK
    local set_token
    do
        local msg_id = make_msg_id()
        local initial_token = 0
        local msg = string.format("SET /locks/1 %016x 42 %s", initial_token, msg_id)
        print("[test] sending SET lock=1 holder=42 to Hi")
        local reply = send_recv(sock, host, hi_client_port, msg)
        if not reply then
            io.stderr:write("FAIL: test b: no reply\n")
            failures = failures + 1
        elseif reply.type ~= "REPLY" or reply.status ~= "OK" or reply.holder ~= 42 then
            io.stderr:write(string.format("FAIL: test b: expected OK holder=42, got status=%s holder=%s\n",
                tostring(reply.status), tostring(reply.holder)))
            failures = failures + 1
        else
            set_token = reply.token
            print(string.format("[test] test b PASS: SET lock=1 holder=42 via Hi -> OK token=%016x", set_token))
        end
    end

    -- Test c: GET lock 1 from Lo -> OK holder=42, token matches test b
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/1 %s", msg_id)
        print("[test] sending GET lock=1 to Lo")
        local reply = send_recv(sock, host, lo_client_port, msg)
        if not reply then
            io.stderr:write("FAIL: test c: no reply\n")
            failures = failures + 1
        elseif reply.type ~= "REPLY" or reply.status ~= "OK" or reply.holder ~= 42 then
            io.stderr:write(string.format("FAIL: test c: expected OK holder=42, got status=%s holder=%s\n",
                tostring(reply.status), tostring(reply.holder)))
            failures = failures + 1
        elseif set_token and reply.token ~= set_token then
            io.stderr:write(string.format("FAIL: test c: token mismatch: expected %016x got %016x\n",
                set_token, reply.token))
            failures = failures + 1
        else
            print("[test] test c PASS: GET lock=1 from Lo -> OK holder=42, token matches")
        end
    end

    -- Test d: SET lock 1 with stale token via Hi -> CONFLICT holder=42
    do
        local msg_id = make_msg_id()
        local stale_token = 0
        local msg = string.format("SET /locks/1 %016x 99 %s", stale_token, msg_id)
        print("[test] sending SET lock=1 with stale token to Hi")
        local reply = send_recv(sock, host, hi_client_port, msg)
        if not reply then
            io.stderr:write("FAIL: test d: no reply\n")
            failures = failures + 1
        elseif reply.type ~= "REPLY" or reply.status ~= "CONFLICT" or reply.holder ~= 42 then
            io.stderr:write(string.format("FAIL: test d: expected CONFLICT holder=42, got status=%s holder=%s\n",
                tostring(reply.status), tostring(reply.holder)))
            failures = failures + 1
        else
            print("[test] test d PASS: SET lock=1 stale token via Hi -> CONFLICT holder=42")
        end
    end

    -- Test e: GET lock 1 from Hi -> still holder=42 (unchanged)
    do
        local msg_id = make_msg_id()
        local msg = string.format("GET /locks/1 %s", msg_id)
        print("[test] sending GET lock=1 to Hi")
        local reply = send_recv(sock, host, hi_client_port, msg)
        if not reply then
            io.stderr:write("FAIL: test e: no reply\n")
            failures = failures + 1
        elseif reply.type ~= "REPLY" or reply.status ~= "OK" or reply.holder ~= 42 then
            io.stderr:write(string.format("FAIL: test e: expected OK holder=42, got status=%s holder=%s\n",
                tostring(reply.status), tostring(reply.holder)))
            failures = failures + 1
        else
            print("[test] test e PASS: GET lock=1 from Hi -> still holder=42")
        end
    end

    udp.close(sock)

    if failures > 0 then
        io.stderr:write("FAIL: " .. failures .. " test(s) failed\n")
        os.exit(1)
    end

    print("PASS: all item05 test client checks passed")
    os.exit(0)
end)
