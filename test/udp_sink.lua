--[[
  UDP Sink

  Listens on 127.0.0.1:20002 and logs all received packets to
  .tmp/udp_sink.20002.log with arrival timestamps.

  Usage:
    ./build/lunet test/udp_sink.lua

  Note: This process stays alive until killed.
]]

local lunet = require("lunet")
local udp = require("lunet.udp")

local function now_us()
    local t = os.clock()
    return math.floor(t * 1000000)
end

local bind_host = "127.0.0.1"
local bind_port = 20002
local out_path = ".tmp/udp_sink.20002.log"

lunet.spawn(function()
    local h, err = udp.bind(bind_host, bind_port)
    assert(h, err)

    while true do
        local line, host, port = udp.recv(h)
        if line and host and port then
            local t2 = now_us()
            local out = line .. " T2_US=" .. t2 .. "\n"
            local f = io.open(out_path, "a")
            if f then
                f:write(out)
                f:close()
            end
        end
    end
end)
