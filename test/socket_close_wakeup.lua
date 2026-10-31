--[[
  Regression test:

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
local SOCK4 = ".tmp/socket_close_wakeup4.sock"
pcall(os.remove, SOCK1)
pcall(os.remove, SOCK2)
pcall(os.remove, SOCK3)
pcall(os.remove, SOCK4)

local woke_with = nil
local queued_clients_eof = false
local write_woke_done = false
local write_woke_err = nil
local write_fast_fail = nil
local accept_after_close_cb = nil
local failures = 0
local accept_attempted = false
local write_in_progress = false

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[CLOSE_WAKEUP] FAIL: " .. msg .. "\n")
end

local function wait_until(predicate, timeout_ms)
    -- os.clock() measures CPU time, which barely advances in an event-loop
    -- process that spends most of its time sleeping/yielding. Use os.time()
    -- (wall clock, second resolution) so the watchdog is actually bounded.
    -- Round up so sub-second budgets still get at least one wall-clock tick.
    local deadline = os.time() + math.max(1, math.ceil(timeout_ms / 1000))
    while not predicate() do
        if os.time() >= deadline then
            return false
        end
        lunet.sleep(1)
    end
    return true
end

-- Wait for a single named condition with its own deadline and a message
-- that names the condition, the expected outcome and the observed state.
local function wait_for(name, predicate, timeout_ms, detail)
    local ok = wait_until(predicate, timeout_ms)
    if not ok then
        fail(name .. ": timed out after " .. tostring(timeout_ms) .. "ms; expected " ..
            tostring(detail and detail.expected or "condition true") ..
            "; observed " .. tostring(detail and detail.observed() or "n/a"))
    end
    return ok
end

-- Case 1: a coroutine parked in socket.accept is woken by socket.close.
lunet.spawn(function()
    local listener, err = socket.listen("unix", SOCK1, 0)
    if not listener then
        fail("listen failed: " .. tostring(err))
        return
    end

    lunet.spawn(function()
        accept_attempted = true
        local client, aerr = socket.accept(listener)
        if client then
            fail("accept unexpectedly returned a client after listener close")
        end
        woke_with = aerr
    end)

    if not wait_until(function()
        return accept_attempted
    end, 250) then
        fail("case1 parked-acceptor: acceptor did not reach socket.accept " ..
            "before close (accept_attempted=" .. tostring(accept_attempted) .. ")")
    end
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

-- Case 3: post-close reuse after the close callback still fails safely.
lunet.spawn(function()
    local listener, err = socket.listen("unix", SOCK3, 0)
    if not listener then
        fail("listen failed: " .. tostring(err))
        return
    end
    socket.close(listener)
    lunet.sleep(50)

    local client, aerr = socket.accept(listener)
    accept_after_close_cb = aerr
    if client ~= nil or aerr ~= "listener closed" then
        fail("accept on closed listener after close callback: client=" .. tostring(client) .. " err=" .. tostring(aerr))
    end
    pcall(os.remove, SOCK3)
end)

-- Case 4: write on a closing socket wakes the parked writer and fails fast.
lunet.spawn(function()
    local listener, err = socket.listen("unix", SOCK4, 0)
    if not listener then
        fail("listen failed: " .. tostring(err))
        return
    end

    local client, cerr = socket.connect(SOCK4, 0)
    if not client then
        fail("connect failed: " .. tostring(cerr))
        socket.close(listener)
        pcall(os.remove, SOCK4)
        return
    end

    local server, aerr = socket.accept(listener)
    if not server then
        fail("accept failed: " .. tostring(aerr))
        socket.close(client)
        socket.close(listener)
        pcall(os.remove, SOCK4)
        return
    end

    lunet.spawn(function()
        local werr = socket.write(client, string.rep("x", 64 * 1024 * 1024))
        write_woke_done = true
        write_woke_err = werr
    end)

    lunet.spawn(function()
        while not write_woke_done and not write_in_progress do
            local err2 = socket.write(client, "probe")
            if err2 == "another write already in progress" then
                write_in_progress = true
                return
            end
            if err2 ~= nil and err2 ~= "socket closed" then
                fail("unexpected probe write result: " .. tostring(err2))
                return
            end
            lunet.sleep(1)
        end
    end)

    if not wait_until(function()
        return write_in_progress or write_woke_done
    end, 1000) then
        fail("case4 parked-writer: writer did not enter in-progress state " ..
            "before close (write_in_progress=" .. tostring(write_in_progress) ..
            ", write_woke_done=" .. tostring(write_woke_done) .. ")")
    end

    socket.close(client)
    write_fast_fail = socket.write(client, "late write")

    socket.close(server)
    socket.close(listener)
    pcall(os.remove, SOCK4)
end)

lunet.spawn(function()
    -- Per-condition deadlines: each wakeup condition gets its own budget and a
    -- named failure message identifying the condition, expected and observed.
    wait_for("condition 1 (parked acceptor wake on listener close)",
        function() return woke_with ~= nil end, 5000,
        { expected = 'woke_with = "listener closed"',
          observed = function()
              return "woke_with=" .. tostring(woke_with)
          end })
    wait_for("condition 2 (queued clients observe EOF after listener close)",
        function() return queued_clients_eof end, 5000,
        { expected = "queued_clients_eof = true",
          observed = function()
              return "queued_clients_eof=" .. tostring(queued_clients_eof)
          end })
    wait_for("condition 3 (post-close accept reports listener closed)",
        function() return accept_after_close_cb ~= nil end, 5000,
        { expected = 'accept_after_close_cb = "listener closed"',
          observed = function()
              return "accept_after_close_cb=" .. tostring(accept_after_close_cb)
          end })
    wait_for("condition 4 (parked writer wake on socket close)",
        function() return write_woke_done end, 5000,
        { expected = 'write_woke_err = "socket closed"',
          observed = function()
              return "write_woke_done=" .. tostring(write_woke_done) ..
                  ", write_woke_err=" .. tostring(write_woke_err)
          end })
    wait_for("condition 5 (write on closed socket fails fast)",
        function() return write_fast_fail ~= nil end, 5000,
        { expected = 'write_fast_fail = "socket closed"',
          observed = function()
              return "write_fast_fail=" .. tostring(write_fast_fail)
          end })

    if woke_with ~= "listener closed" then
        fail("condition 1 (parked acceptor wake): expected listener closed, got " .. tostring(woke_with))
    end
    if not queued_clients_eof then
        fail("condition 2 (queued clients EOF): did not complete as expected")
    end
    if accept_after_close_cb ~= "listener closed" then
        fail("condition 3 (post-close accept): expected listener closed, got " .. tostring(accept_after_close_cb))
    end
    if write_woke_err ~= "socket closed" then
        fail("condition 4 (parked writer wake): expected socket closed, got " .. tostring(write_woke_err))
    end
    if write_fast_fail ~= "socket closed" then
        fail("condition 5 (fast-fail write): expected socket closed, got " .. tostring(write_fast_fail))
    end

    if failures > 0 then
        _G.__lunet_exit_code = 1
        os.exit(1)
    end
    print("[CLOSE_WAKEUP] PASSED")
    _G.__lunet_exit_code = 0
    os.exit(0)
end)
