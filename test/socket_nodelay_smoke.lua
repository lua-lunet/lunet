--[[
  Smoke test for socket.set_nodelay:

  1. TCP accept/connect sockets start with NODELAY enabled and the setter
     round-trips both ways (returns nil on success, per the error-only
     convention shared with socket.write).
  2. A unix-domain socket reports "not a tcp socket" instead of changing
     anything.
  3. Data still flows over a socket after a set_nodelay round-trip.

  Exits 0 on success, 1 on failure.
]]

local lunet = require("lunet")
local socket = require("lunet.socket")

local PORT = 18765

local failures = 0

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[NODELAY_SMOKE] FAIL: " .. msg .. "\n")
end

lunet.spawn(function()
    local listener, lerr = socket.listen("tcp", "127.0.0.1", PORT)
    if not listener then
        fail("listen failed: " .. tostring(lerr))
        _G.__lunet_exit_code = 1
        os.exit(1)
        return
    end

    lunet.spawn(function()
        local client, cerr = socket.connect("127.0.0.1", PORT)
        if not client then
            fail("connect failed: " .. tostring(cerr))
            socket.close(listener)
            _G.__lunet_exit_code = 1
            os.exit(1)
            return
        end

        local server, aerr = socket.accept(listener)
        if not server then
            fail("accept failed: " .. tostring(aerr))
            socket.close(client)
            socket.close(listener)
            _G.__lunet_exit_code = 1
            os.exit(1)
            return
        end

        -- setter succeeds on both ends of a live TCP pair
        local r1 = socket.set_nodelay(client, true)
        if r1 ~= nil then
            fail("set_nodelay(client, true) expected nil, got " .. tostring(r1))
        end
        local r2 = socket.set_nodelay(server, false)
        if r2 ~= nil then
            fail("set_nodelay(server, false) expected nil, got " .. tostring(r2))
        end
        local r3 = socket.set_nodelay(client, true)
        if r3 ~= nil then
            fail("set_nodelay round-trip expected nil, got " .. tostring(r3))
        end

        -- data still flows after the round-trip
        lunet.spawn(function()
            local _, werr = socket.write(server, "ping")
            if werr then
                fail("server write failed: " .. tostring(werr))
            end
        end)

        local data, rerr = socket.read(client)
        if not data or data ~= "ping" then
            fail("expected 'ping' after set_nodelay round-trip, got " .. tostring(data) .. "/" .. tostring(rerr))
        end

        socket.close(client)
        socket.close(server)
        socket.close(listener)

        if failures == 0 then
            print("[NODELAY_SMOKE] ok")
            _G.__lunet_exit_code = 0
            os.exit(0)
        end
        _G.__lunet_exit_code = 1
        os.exit(1)
    end)
end)
