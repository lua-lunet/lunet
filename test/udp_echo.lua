--[[
  UDP Echo Server

  A simple UDP echo server that listens on 127.0.0.1:20001.
  It expects packets with "REPLY_PORT=nnnn" and echoes back to that port.

  Usage:
    ./build/lunet test/udp_echo.lua

  Note: This process stays alive until killed.
]]

local lunet = require("lunet")
local udp = require("lunet.udp")

local function now_us()
    local t = os.clock()
    return math.floor(t * 1000000)
end

local bind_host = "127.0.0.1"
local bind_port = 20001
local reply_host = "127.0.0.1"

lunet.spawn(function()
    local h, err = udp.bind(bind_host, bind_port)
    assert(h, err)

    while true do
        local line, host, port = udp.recv(h)
        if line and host and port then
            local reply_port = tonumber(line:match("REPLY_PORT=(%d+)"))
            if reply_port then
                local t1 = now_us()
                local out = line .. " T1_US=" .. t1
                udp.send(h, reply_host, reply_port, out)
            end
        end
    end
end)
