--[[
  Regression test for Issue #50 class bug:

  If a socket listener is created inside a short-lived coroutine that returns
  synchronously (never yields), that coroutine can be garbage collected.

  Any long-lived C handle must NOT store that coroutine's lua_State* and later
  use it for registry operations inside callbacks (lua_rawgeti crashes).

  This test:
    1) Creates a unix listener in a spawn() that returns immediately.
    2) Forces GC to collect the setup coroutine if possible.
    3) Performs accept/connect/read/write to ensure callbacks stay stable.
]]

local lunet = require("lunet")
local socket = require("lunet.socket")

local sock_path = ".tmp/socket_listener_gc.sock"
pcall(os.remove, sock_path)

local listener

-- Create listener inside a coroutine that finishes synchronously (no yield).
lunet.spawn(function()
    local l, err = socket.listen("unix", sock_path, 0)
    if not l then
        error("listen failed: " .. tostring(err))
    end
    listener = l
end)

lunet.spawn(function()
    -- Wait until listener is ready.
    while not listener do
        lunet.sleep(1)
    end

    -- Attempt to collect the setup coroutine.
    for _ = 1, 5 do
        collectgarbage("collect")
    end

    -- Server: accept one client, read ping, write pong.
    lunet.spawn(function()
        local client, aerr = socket.accept(listener)
        if not client then
            io.stderr:write("[SOCKET_GC] accept failed: " .. tostring(aerr) .. "\n")
            _G.__lunet_exit_code = 1
            return
        end

        local data, rerr = socket.read(client)
        if data ~= "ping" then
            io.stderr:write("[SOCKET_GC] read failed: data=" .. tostring(data) ..
                " err=" .. tostring(rerr) .. "\n")
            pcall(socket.close, client)
            pcall(socket.close, listener)
            _G.__lunet_exit_code = 1
            return
        end

        local werr = socket.write(client, "pong")
        if werr then
            io.stderr:write("[SOCKET_GC] write failed: " .. tostring(werr) .. "\n")
            pcall(socket.close, client)
            pcall(socket.close, listener)
            _G.__lunet_exit_code = 1
            return
        end

        socket.close(client)
        socket.close(listener)
        pcall(os.remove, sock_path)

        print("[SOCKET_GC] PASSED")
        _G.__lunet_exit_code = 0
    end)

    -- Client: connect, send ping, read pong.
    lunet.spawn(function()
        lunet.sleep(10) -- let accept() arm and yield
        local conn, cerr = socket.connect(sock_path, 0)
        if not conn then
            io.stderr:write("[SOCKET_GC] connect failed: " .. tostring(cerr) .. "\n")
            _G.__lunet_exit_code = 1
            return
        end

        local werr = socket.write(conn, "ping")
        if werr then
            io.stderr:write("[SOCKET_GC] client write failed: " .. tostring(werr) .. "\n")
            pcall(socket.close, conn)
            _G.__lunet_exit_code = 1
            return
        end

        local resp, rerr = socket.read(conn)
        if resp ~= "pong" then
            io.stderr:write("[SOCKET_GC] client read failed: resp=" .. tostring(resp) ..
                " err=" .. tostring(rerr) .. "\n")
            pcall(socket.close, conn)
            _G.__lunet_exit_code = 1
            return
        end

        socket.close(conn)
    end)
end)

