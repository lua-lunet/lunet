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

---Request a deliberate stop of the event loop. The run stops taking new
---work, the drain point is reached (the on_stop hook fires), every remaining
---handle is closed, and the run's exit code is then reported. Safe to call
---more than once.
---@return nil
---@usage
---```lua
---local lunet = require('lunet')
---lunet.on_stop(function()
---    print("Draining: state is final here")
---end)
---lunet.stop()
---```
function lunet.stop() end

---Register the post-drain hook (replaces any previously registered one).
---Called exactly once at the drain point: in-memory state is final and no
---handle has been closed yet. The event loop is no longer driving anything
---while the callback runs, so only synchronous work may happen here.
---@param fn function The post-drain callback
---@return nil
function lunet.on_stop(fn) end

return lunet
