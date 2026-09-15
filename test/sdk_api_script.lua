local lunet = require("lunet")

assert(type(lunet.sleep) == "function")
assert(type(lunet.stop) == "function")
assert(type(lunet.on_stop) == "function")

-- Deliberate stop contract: an early coroutine finishes before the stop
-- request; the on_stop hook fires exactly once at the drain point with that
-- state visible, then the exit code is reported to the C SDK caller.
local early_task_done = false
local on_stop_calls = 0

lunet.spawn(function()
    lunet.sleep(1)
    early_task_done = true
end)

lunet.on_stop(function()
    on_stop_calls = on_stop_calls + 1
    -- sdk-api-test expects exit code 23, and it must be observable only
    -- through the post-drain hook: if the hook never fires, the exit code
    -- stays 24 and the C test fails.
    __lunet_exit_code = (on_stop_calls == 1 and early_task_done) and 23 or 24
end)

lunet.spawn(function()
    lunet.sleep(20)
    lunet.stop()
end)

__lunet_exit_code = 24
