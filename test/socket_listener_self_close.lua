--[[
  Regression test for item24 / issue #145 class bug.

  If listen_cb hits the catastrophic self-close path, the listener handle that
  Lua still holds must become invalid instead of dangling. A later
  socket.close(listener) must be safe.

  This test requires the caller to run it with
  LUNET_TEST_SOCKET_LISTEN_FAULT="alloc_fail,drop_fail" set (Lua has no
  os.setenv, so this test cannot set it on itself -- see xmake.lua's
  `stress` task, which supplies it via os.execv's `envs` table). That
  combination forces lunet_listen_cb's alloc-failure path to also fail
  lunet_listen_drop_conn(), which is what actually drives the listener into
  the catastrophic self-close path (ctx->closing = 1; uv_close() on the
  listener itself). Without both faults active the listener just accepts
  normally and this test never exercises the path it's named for; fail
  loudly instead of silently passing in that case.

  socket.close() on an already-invalidated handle (ctx == NULL, i.e. the
  underlying socket_ctx_t was already torn down) returns a single nil
  value, not the "invalid socket handle" string -- that string is only
  produced when the argument fails socket_handle_check() entirely (not a
  socket userdata at all). See lunet_socket_close() in src/socket.c.

  Exits 0 on success, 1 on failure.
]]

local FAULT_MODE = os.getenv("LUNET_TEST_SOCKET_LISTEN_FAULT")
if not (FAULT_MODE and FAULT_MODE:find("alloc_fail", 1, true) and
        FAULT_MODE:find("drop_fail", 1, true)) then
    io.stderr:write(
        "[LISTENER_SELF_CLOSE] FAIL: LUNET_TEST_SOCKET_LISTEN_FAULT must " ..
        "include both alloc_fail and drop_fail to exercise the " ..
        "catastrophic self-close path (got: " .. tostring(FAULT_MODE) ..
        ")\n")
    os.exit(1)
end

local lunet = require("lunet")
local socket = require("lunet.socket")

local listener
local port = 19191
local failures = 0

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[LISTENER_SELF_CLOSE] FAIL: " .. msg .. "\n")
end

lunet.spawn(function()
    local l, err = socket.listen("tcp", "127.0.0.1", port)
    if not l then
        fail("listen failed: " .. tostring(err))
        os.exit(1)
    end
    listener = l

    lunet.spawn(function()
        lunet.sleep(10)
        local client, cerr = socket.connect("127.0.0.1", port)
        if client then
            socket.close(client)
        elseif cerr then
            fail("connect failed to trigger listen_cb fault: " .. tostring(cerr))
        end
    end)

    lunet.spawn(function()
        lunet.sleep(80)
        local err2 = socket.close(listener)
        if err2 ~= nil then
            fail("unexpected close result after listener teardown: " .. tostring(err2))
        end
        if failures > 0 then
            _G.__lunet_exit_code = 1
            os.exit(1)
        end
        print("[LISTENER_SELF_CLOSE] PASSED")
        _G.__lunet_exit_code = 0
        os.exit(0)
    end)
end)
