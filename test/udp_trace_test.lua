--[[
  UDP Trace Test

  Verifies basic UDP tracing: BIND, TX, and CLOSE statistics.
  Tests that closing a handle correctly reports local and global tx/rx counts.

  Usage:
    ./build/lunet test/udp_trace_test.lua

  Expected Trace Output (LUNET_TRACE=ON):
    [UDP_TRACE] BIND #1 127.0.0.1:<port>
    [UDP_TRACE] TX #1 -> 127.0.0.1:20001 (4 bytes)
    [UDP_TRACE] CLOSE (local: tx=1 rx=0) (global: tx=1 rx=0)
]]

local lunet = require("lunet")
local udp = require("lunet.udp")

lunet.spawn(function()
    local h, err = udp.bind("127.0.0.1", 0)
    if not h then
        print("Bind failed: " .. tostring(err))
        return
    end
    print("Test bound")

    local ok, serr = udp.send(h, "127.0.0.1", 20001, "ping")
    if not ok then
        print("Send failed: " .. tostring(serr))
    end

    print("Closing handle")
    udp.close(h)
    print("Handle closed")
end)
