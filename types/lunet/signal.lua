---@meta

---@class signal
local signal = {}

---Wait for a signal (must be called from coroutine)
---@param name string The name of the signal to wait for ("INT", "TERM", "HUP", "QUIT")
---@return string|nil signal The name of the signal that was received or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local signal = require('lunet.signal')
---lunet.spawn(function()
---    local sig, err = signal.wait('INT')
---    if err then
---        print('Error waiting for signal: ' .. err)
---    else
---        print('Signal received: ' .. sig)
---    end
---end)
---```
function signal.wait(name) end

return signal
