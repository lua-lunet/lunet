--[[
  UDP Echo Client

  Sends a single packet to the echo server (port 20001) and exits.

  Usage:
    ./build/lunet test/udp_echo_client.lua
]]

local lunet = require("lunet")
local udp = require("lunet.udp")

local function now_us()
    local t = os.clock()
    return math.floor(t * 1000000)
end

local dest_host = "127.0.0.1"
local dest_port = 20001
local reply_port = 20002
local src_id = "client1"
local seq = 1

lunet.spawn(function()
    local h, err = udp.bind("127.0.0.1", 0)
    assert(h, err)
    local t0 = now_us()
    local line = "V=1 SRC=" .. src_id .. " SEQ=" .. seq .. " REPLY_PORT=" .. reply_port ..
        " T0_US=" .. t0 .. " PAYLOAD=hello"
    local ok, serr = udp.send(h, dest_host, dest_port, line)
    assert(ok, serr)
end)
