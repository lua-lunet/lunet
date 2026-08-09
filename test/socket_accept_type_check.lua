--[[
  Regression test for P1-D: lunet_socket_accept must reject a client
  (SOCKET_CLIENT) handle instead of reading server-arm union fields
  (accept_ref / pending_accepts) through the client arm's overlay.

  Before the fix, socket.accept(clientHandle) read garbage through the
  read_ref/write_ref overlay and parked the coroutine forever while also
  corrupting the client's read_ref slot. This test asserts accept() on a
  connected client handle returns an error immediately.

  Exits 0 on success, 1 on failure.
]]

local lunet = require("lunet")
local socket = require("lunet.socket")

local SOCK = ".tmp/socket_accept_type_check.sock"
pcall(os.remove, SOCK)

local failures = 0

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[ACCEPT_TYPE_CHECK] FAIL: " .. msg .. "\n")
end

lunet.spawn(function()
    local listener, lerr = socket.listen("unix", SOCK, 0)
    if not listener then
        fail("listen failed: " .. tostring(lerr))
        _G.__lunet_exit_code = 1
        os.exit(1)
        return
    end

    local client, cerr = socket.connect(SOCK, 0)
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

    -- The bug: calling accept() on a CLIENT handle must not park or corrupt
    -- state. It must return an error immediately.
    local result, err = socket.accept(client)
    if result ~= nil then
        fail("accept on client handle unexpectedly returned a value: " .. tostring(result))
    end
    if err ~= "not a listening socket" then
        fail("accept on client handle returned wrong error: " .. tostring(err))
    end

    -- The client must still be usable afterward (no corrupted read_ref).
    local read_err
    local read_done = false
    lunet.spawn(function()
        local data, rerr = socket.read(client)
        read_done = true
        if data ~= nil or rerr == nil then
            read_err = "unexpected read result: data=" .. tostring(data) .. " err=" .. tostring(rerr)
        end
    end)

    socket.close(server)
    socket.close(client)
    socket.close(listener)
    pcall(os.remove, SOCK)

    local deadline = os.clock() + 1
    while not read_done and os.clock() < deadline do
        lunet.sleep(1)
    end
    if not read_done then
        fail("read after accept-misuse did not complete (client state corrupted)")
    elseif read_err then
        fail(read_err)
    end

    if failures > 0 then
        _G.__lunet_exit_code = 1
        os.exit(1)
    end
    print("[ACCEPT_TYPE_CHECK] PASSED")
    _G.__lunet_exit_code = 0
    os.exit(0)
end)
