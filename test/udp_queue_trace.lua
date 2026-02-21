--[[
  UDP Queue Trace Test

  Verifies that packets retrieved from the internal pending queue are
  correctly traced using RECV_DELIVER (instead of RECV_RESUME).

  Scenario:
    1. Sink binds and sleeps for 1s.
    2. Client sends 2 packets rapidly.
    3. Packets are queued in the C context.
    4. Sink wakes up and calls recv() twice.
    5. Both should show RECV_DELIVER trace.

  Usage:
    ./build/lunet test/udp_queue_trace.lua
]]

local lunet = require("lunet")
local udp = require("lunet.udp")

lunet.spawn(function()
    local h, err = udp.bind("127.0.0.1", 20003)
    assert(h, err)
    print("SINK: Ready")
    lunet.sleep(1) -- Wait for packets to arrive and queue up

    print("SINK: Recv 1")
    local d1 = udp.recv(h)
    print("SINK: Got 1: " .. d1)

    print("SINK: Recv 2")
    local d2 = udp.recv(h)
    print("SINK: Got 2: " .. d2)

    udp.close(h)
end)

lunet.spawn(function()
    lunet.sleep(0.1)
    local h = udp.bind("127.0.0.1", 0)
    print("CLIENT: Send 1")
    udp.send(h, "127.0.0.1", 20003, "packet1")
    lunet.sleep(0.1) -- Ensure packet is sent
    print("CLIENT: Send 2")
    udp.send(h, "127.0.0.1", 20003, "packet2")
    lunet.sleep(0.1) -- Ensure packet is sent
    udp.close(h)
end)
