--[[
  Regression coverage for listen_cb error-handling branches:
    1) waiter registry slot is invalid -> accepted connection is queued
    2) queueing fails -> accepted connection is dropped
    3) alloc failure + drop failure -> listener closes and wakes parked accept

  Combined fault modes accept either "+" or "," as the separator between
  fault names (LUNET_TEST_SOCKET_LISTEN_FAULT parser in src/socket.c
  treats both identically), e.g. "alloc_fail+drop_fail" or
  "alloc_fail,drop_fail".

  Exits 0 on success, 1 on failure.
]]

local lunet = require("lunet")
local socket = require("lunet.socket")

local HOST = "127.0.0.1"
local TCP_PORT = tonumber(os.getenv("TEST_TCP_PORT")) or 19183
local MODE = os.getenv("LUNET_TEST_SOCKET_LISTEN_FAULT")
local WATCHDOG_MS = tonumber(os.getenv("TEST_WATCHDOG_MS")) or 1500

local failures = 0

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[SOCKET_LISTEN_ERROR] FAIL: " .. msg .. "\n")
    _G.__lunet_exit_code = 1
    os.exit(1)
end

local function pass(msg)
    print("[SOCKET_LISTEN_ERROR] PASSED " .. msg)
    _G.__lunet_exit_code = 0
    os.exit(0)
end

local function must_listen()
    local listener, err = socket.listen("tcp", HOST, TCP_PORT)
    if not listener then
        fail("listen failed: " .. tostring(err))
    end
    return listener
end

local function must_connect()
    local conn, err = socket.connect(HOST, TCP_PORT)
    if not conn then
        fail("connect failed: " .. tostring(err))
    end
    return conn
end

lunet.spawn(function()
    if MODE == "nonthread_waiter" then
        -- lunet_listen_cb (src/socket.c) clears ctx->server.accept_ref and
        -- pulls the registry slot's value *before* checking lua_isthread on
        -- it. Under this fault the slot is forced to a boolean instead of
        -- the waiting coroutine, so the "waiter's registry slot was not a
        -- coroutine" branch runs: the already-accepted connection is parked
        -- on ctx->server.pending_accepts via lunet_pending_accept_enqueue,
        -- and the first waiter is never touched again. Since accept_ref was
        -- already cleared, that first coroutine's socket.accept call is never
        -- resumed by anything — it is permanently stranded, not resumed with
        -- a nil error. The only observable, correct behavior is that the
        -- connection surfaces on a *later* socket.accept call for the same
        -- listener (the queue-fallback path).
        local listener = must_listen()
        local accepted
        local first_returned = false

        lunet.spawn(function()
            -- This call's registry slot gets corrupted by the fault, so
            -- lunet_listen_cb queues the connection instead of resuming us.
            -- We must never observe a return here; if we did, the queue
            -- fallback did not run and the connection was (incorrectly)
            -- delivered straight to this waiter instead.
            socket.accept(listener)
            first_returned = true
        end)

        lunet.spawn(function()
            lunet.sleep(10)
            local conn = must_connect()
            lunet.sleep(50)
            socket.close(conn)
        end)

        lunet.spawn(function()
            lunet.sleep(250)
            local client, err = socket.accept(listener)
            if not client then
                fail("queued fallback accept failed: " .. tostring(err))
            end
            accepted = client
        end)

        lunet.spawn(function()
            lunet.sleep(400)
            if first_returned then
                fail("first corrupted waiter must never resume (it is stranded, " ..
                     "not woken); its resuming means the connection leaked to " ..
                     "it instead of being queued")
            end
            if not accepted then
                fail("fallback connection was not queued for later accept")
            end
            socket.close(accepted)
            socket.close(listener)
            pass("queue_fallback")
        end)
    elseif MODE == "queue_fail" then
        local listener = must_listen()

        lunet.spawn(function()
            lunet.sleep(10)
            local conn = must_connect()
            local data, err = socket.read(conn)
            if data ~= nil or err ~= nil then
                fail("dropped client should observe EOF only: data=" .. tostring(data) .. " err=" .. tostring(err))
            end
            socket.close(conn)
        end)

        lunet.spawn(function()
            lunet.sleep(250)
            socket.close(listener)
            pass("queue_drop")
        end)
    elseif MODE == "alloc_fail" or MODE == "drop_fail" then
        fail("catastrophic path needs both alloc_fail and drop_fail")
    elseif MODE == "alloc_fail+drop_fail" or MODE == "alloc_fail,drop_fail" then
        local listener = must_listen()
        local woke_err

        lunet.spawn(function()
            local client, err = socket.accept(listener)
            if client ~= nil then
                fail("catastrophic path unexpectedly produced a client")
            end
            woke_err = err
        end)

        lunet.spawn(function()
            lunet.sleep(10)
            local conn = must_connect()
            local data, err = socket.read(conn)
            if data ~= nil or err ~= nil then
                fail("catastrophic client should observe EOF only: data=" .. tostring(data) .. " err=" .. tostring(err))
            end
            socket.close(conn)
        end)

        lunet.spawn(function()
            lunet.sleep(250)
            if woke_err ~= "out of memory" then
                fail("parked accept was not woken with catastrophic error: " .. tostring(woke_err))
            end
            local client, err = socket.accept(listener)
            if client ~= nil or err ~= "listener closed" then
                fail("listener was not closed after catastrophic failure: client=" .. tostring(client)
                    .. " err=" .. tostring(err))
            end
            pass("catastrophic_close")
        end)
    else
        fail("unsupported mode: " .. tostring(MODE))
    end

    lunet.spawn(function()
        lunet.sleep(WATCHDOG_MS)
        fail("watchdog expired in mode " .. tostring(MODE))
    end)
end)
