---@meta

---Lunet - A coroutine-based libuv binding for LuaJIT
---@class lunet
local lunet = {}

---Sleep for specified milliseconds (coroutine-style)
---@param ms integer Sleep duration in milliseconds
---@return nil
---@usage
---```lua
---local lunet = require('lunet')
---lunet.sleep(1000)  -- Sleep for 1 second
---```
function lunet.sleep(ms) end

---Spawn a new coroutine
---@param func function The function to run in the new coroutine
---@return nil
---@usage
---```lua
---local lunet = require('lunet')
---lunet.spawn(function()
---    print("Hello from coroutine!")
---    lunet.sleep(1000)
---    print("After 1 second")
---end)
---```
function lunet.spawn(func) end

return lunet
