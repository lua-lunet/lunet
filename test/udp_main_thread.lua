--[[
  UDP Main Thread Test

  Verifies that calling UDP functions from the main Lua thread (outside
  a coroutine) correctly fails with an error message.

  Usage:
    ./build/lunet test/udp_main_thread.lua

  Expected Output:
    Error: udp.bind must be called from coroutine
]]

local udp = require("lunet.udp")
local h, err = udp.bind("127.0.0.1", 0)
print(h, err)
