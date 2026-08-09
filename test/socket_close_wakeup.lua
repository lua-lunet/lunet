--[[
  Regression test for issue #145 defect D:

  Closing a listener must wake a coroutine parked in socket.accept
  (previously it hung forever with its coref leaked), and must close
  connections that were accepted but never delivered (previously leaked,
  because queue_destroy does not free payloads).

  Also pins the refuse-to-repark guard: accept/read on a closing handle
  must return an error immediately instead of yielding forever.

  Exits 0 on success, 1 on failure.
]]

local lunet = require("lunet")
local socket = require("lunet.socket")

local SOCK1 = ".tmp/socket_close_wakeup.sock"
local SOCK2 = ".tmp/socket_close_wakeup2.sock"
local SOCK3 = ".tmp/socket_close_wakeup3.sock"
pcall(os.remove, SOCK1)
pcall(os.remove, SOCK2)
pcall(os.remove, SOCK3)

local woke_with = nil
local queued_clients_eof = false
local failures = 0

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[CLOSE_WAKEUP] FAIL: " .. msg .. "\n")
end

-- Case 1: a coroutine parked in socket.accept is woken by socket.close.
lunet.spawn(function()
    local listener, err = socket.listen("unix", SOCK1, 0)
    if not listener then
        fail("listen failed: " .. tostring(err))
        return
    end

    lunet.spawn(function()
        local client, aerr = socket.accept(listener)
        if client then
            fail("accept unexpectedly returned a client after listener close")
        end
        woke_with = aerr
    end)

    lunet.sleep(50) -- let the acceptor park
    socket.close(listener)
    pcall(os.remove, SOCK1)
end)

-- Case 2: connections queued but never accepted are closed with the listener.
lunet.spawn(function()
    local listener, err = socket.listen("unix", SOCK2, 0)
    if not listener then
        fail("listen failed: " .. tostring(err))
        return
    end

    local c1, cerr1 = socket.connect(SOCK2, 0)
    local c2, cerr2 = socket.connect(SOCK2, 0)
    if not c1 or not c2 then
        fail("connect failed: " .. tostring(cerr1) .. " / " .. tostring(cerr2))
        return
    end

    lunet.sleep(50) -- let both connections queue on the listener (never accepted)
    socket.close(listener)

    -- The queued server-side handles were closed, so the clients see EOF.
    local d1 = socket.read(c1)
    local d2 = socket.read(c2)
    if d1 == nil and d2 == nil then
        queued_clients_eof = true
    else
        fail("queued clients did not observe close: d1=" .. tostring(d1) .. " d2=" .. tostring(d2))
    end

    socket.close(c1)
    socket.close(c2)
    pcall(os.remove, SOCK2)
end)

-- Case 3: accept/read on a closing handle refuse instead of parking forever.
lunet.spawn(function()
    local listener, err = socket.listen("unix", SOCK3, 0)
    if not listener then
        fail("listen failed: " .. tostring(err))
        return
    end
    socket.close(listener)

    local client, aerr = socket.accept(listener)
    if client ~= nil or aerr ~= "listener closed" then
        fail("accept on closed listener: client=" .. tostring(client) .. " err=" .. tostring(aerr))
    end
    pcall(os.remove, SOCK3)
end)

lunet.spawn(function()
    lunet.sleep(300)

    if woke_with ~= "listener closed" then
        fail("parked acceptor was not woken by listener close (got " .. tostring(woke_with) .. ")")
    end
    if not queued_clients_eof then
        fail("queued-clients case did not complete as expected")
    end

    if failures > 0 then
        _G.__lunet_exit_code = 1
        os.exit(1)
    end
    print("[CLOSE_WAKEUP] PASSED")
    _G.__lunet_exit_code = 0
    os.exit(0)
end)
