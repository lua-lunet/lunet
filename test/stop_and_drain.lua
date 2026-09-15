--[[
  Runtime shutdown integration test: deliberate stop, drain point, and the
  post-drain on_stop hook, plus clean teardown of every remaining handle.

  Covers the three runtime termination requirements:

  1.  A deliberate stop: lunet.stop() ends the event loop promptly, from Lua;
      calling it a second time (including from inside the callback) is a
      safe no-op.
  2.  A post-drain notification: the on_stop callback runs exactly once at
      the drain point, after work accepted before the stop request has
      completed, and can read the final in-memory state. It persists that
      state here by writing the marker file (the same safe point where a
      host would write its WAL and record the superblock flushed flag).
  3.  Clean teardown: after the callback, the runtime closes every remaining
      handle (the open listener with a coroutine parked in accept, the bound
      UDP socket, any sleep timer still in flight), drains the close
      callbacks, and the process exits promptly with exit code 0 -- no stray
      uv_loop_close failure output and no hang.

  The parked-accept coroutine appends "w" to the marker file when the
  tear-down wakes it, so the driver asserts the marker is exactly "okw".

  Exits 0 on success, 1 on failure. The xmake "stress" task drives this
  file with lunet-run and asserts both the exit code and the marker file.
]]

local lunet = require("lunet")
local socket = require("lunet.socket")
local udp = require("lunet.udp")

local MARKER = ".tmp/stop_and_drain.marker"

pcall(os.remove, MARKER)

local failures = 0

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[STOP_DRAIN] FAIL: " .. msg .. "\n")
end

-- State that must be final by the time on_stop runs.
local accepted_before_stop_done = false

lunet.spawn(function()
    lunet.sleep(1)
    accepted_before_stop_done = true
end)

local on_stop_calls = 0

lunet.on_stop(function()
    on_stop_calls = on_stop_calls + 1
    if on_stop_calls > 1 then
        fail("on_stop must be invoked exactly once at the drain point")
    end
    if not accepted_before_stop_done then
        fail("work accepted before the stop request must have completed")
    end
    -- The hook runs before teardown: synchronous I/O only (an async write
    -- here could never be driven because the loop is no longer running).
    local fh = io.open(MARKER, "w")
    if not fh then
        fail("on_stop could not write the marker file")
        return
    end
    fh:write(on_stop_calls == 1 and "ok" or "reentered")
    fh:close()
    -- A second stop request after the drain point must be a no-op.
    lunet.stop()
end)

-- Open handles that the tear-down must close after the drain point: a
-- listener with a coroutine parked in accept, and a bound UDP socket.
-- Loopback binding so test parity holds on every platform. The parked
-- accept coroutine is woken with an error only when the tear-down closes
-- the listener (after the on_stop hook has run) -- it appends "w" to the
-- marker file so the driver can observe that the wake-up happened.
lunet.spawn(function()
    -- Ephemeral port pick with collision fallback (port 0 is rejected).
    local listener, lerr = nil, nil
    local base = 20000 + (math.floor(os.clock() * 1000) % 30000)
    for attempt = 0, 4 do
        listener, lerr = socket.listen("tcp", "127.0.0.1", base + attempt * 97)
        if listener then
            break
        end
    end
    if not listener then
        fail("listen failed: " .. tostring(lerr))
        return
    end
    local unbound, uerr = udp.bind("127.0.0.1", 0)
    if not unbound then
        fail("udp.bind failed: " .. tostring(uerr))
        return
    end
    lunet.spawn(function()
        local _, werr = socket.accept(listener)
        local fh = io.open(MARKER, "a")
        if fh then
            fh:write(werr and "w" or "!")
            fh:close()
        end
    end)
end)

-- Request the deliberate stop from a coroutine after the early task.
lunet.spawn(function()
    lunet.sleep(15)
    lunet.stop()
end)

__lunet_exit_code = failures == 0 and 0 or 1
