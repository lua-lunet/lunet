---@meta

---@class signal
local signal = {}

---Wait for a signal (must be called from coroutine).
---
---One-shot: the FIRST matching signal resumes the waiter with the signal name
---and tears the watcher down. While the watcher is armed the process default
---is overridden — e.g. the first SIGTERM is delivered to this coroutine and
---does NOT terminate the process. To stop the process on TERM, exit from the
---handler (os.exit, or set _G.__lunet_exit_code and close your listeners so
---the event loop drains).
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
---        os.exit(0)  -- signal.wait is one-shot; exiting is your job
---    end
---end)
---```
function signal.wait(name) end

return signal
