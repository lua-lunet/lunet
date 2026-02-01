local lunet = require("lunet")
local udp = require("lunet.udp")

local PORT_A = 19998
local PORT_B = 19999
local HOST = "127.0.0.1"

local function test_udp()
    local a, err = udp.bind(HOST, PORT_A)
    if not a then
        print("FAIL: bind A: " .. tostring(err))
        __lunet_exit_code = 1
        return
    end

    local b, err2 = udp.bind(HOST, PORT_B)
    if not b then
        print("FAIL: bind B: " .. tostring(err2))
        udp.close(a)
        __lunet_exit_code = 1
        return
    end

    lunet.spawn(function()
        local data, from_host, from_port = udp.recv(b)
        if not data then
            print("FAIL: recv on B failed")
            __lunet_exit_code = 1
            return
        end
        if data ~= "ping" then
            print("FAIL: expected 'ping', got '" .. data .. "'")
            __lunet_exit_code = 1
            return
        end
        udp.send(b, from_host, from_port, "pong")
    end)

    local ok, err3 = udp.send(a, HOST, PORT_B, "ping")
    if not ok then
        print("FAIL: send from A: " .. tostring(err3))
        __lunet_exit_code = 1
        return
    end

    local reply, _, _ = udp.recv(a)
    if not reply then
        print("FAIL: recv on A failed")
        __lunet_exit_code = 1
        return
    end
    if reply ~= "pong" then
        print("FAIL: expected 'pong', got '" .. reply .. "'")
        __lunet_exit_code = 1
        return
    end

    udp.close(a)
    udp.close(b)

    print("OK: UDP ping-pong")
    __lunet_exit_code = 0
end

lunet.spawn(test_udp)
