--[[
  Regression test for issue #145: a coroutine looping on socket.accept must
  be resumed for every established TCP client while the same process runs
  concurrent UDP receive/heartbeat traffic.

  Single process, documented APIs only:
    - TCP listener with an accept loop spawning an echo handler per client
    - UDP socket answering heartbeat datagrams
    - concurrent TCP clients (connect/write/read/close)
    - concurrent UDP heartbeat senders
    - watchdog: fails fast instead of hanging if any accept is lost

  Exits 0 on success, 1 on failure.
]]

local lunet = require("lunet")
local socket = require("lunet.socket")
local udp = require("lunet.udp")

local HOST = "127.0.0.1"
local TCP_PORT = tonumber(os.getenv("TEST_TCP_PORT")) or 19181
local UDP_PORT = tonumber(os.getenv("TEST_UDP_PORT")) or 19182
local CLIENTS = tonumber(os.getenv("TEST_CLIENTS")) or 32
local HBS = tonumber(os.getenv("TEST_HBS")) or 200
local WATCHDOG_MS = tonumber(os.getenv("TEST_WATCHDOG_MS")) or 5000

local accepts = 0
local client_errors = 0
local tcp_done = 0
local udp_acked = 0
local failed = false

local function fail(msg)
    if failed then
        return
    end
    failed = true
    io.stderr:write("[ACCEPT_UDP] FAIL: " .. msg .. "\n")
    _G.__lunet_exit_code = 1
    os.exit(1)
end

local function maybe_pass()
    if tcp_done == CLIENTS and udp_acked == HBS and not failed then
        print(string.format("[ACCEPT_UDP] PASSED clients=%d accepts=%d udp_acked=%d client_errors=%d",
            CLIENTS, accepts, udp_acked, client_errors))
        _G.__lunet_exit_code = 0
        os.exit(0)
    end
end

lunet.spawn(function()
    local listener, lerr = socket.listen("tcp", HOST, TCP_PORT)
    if not listener then
        fail("listen failed: " .. tostring(lerr))
    end
    local hb, herr = udp.bind(HOST, UDP_PORT)
    if not hb then
        fail("udp.bind failed: " .. tostring(herr))
    end

    -- Accept loop
    lunet.spawn(function()
        while true do
            local client, aerr = socket.accept(listener)
            if not client then
                fail("accept failed: " .. tostring(aerr))
            end
            accepts = accepts + 1
            lunet.spawn(function()
                local data = socket.read(client)
                if data then
                    socket.write(client, "pong:" .. data)
                else
                    client_errors = client_errors + 1
                end
                socket.close(client)
            end)
        end
    end)

    -- UDP heartbeat responder
    lunet.spawn(function()
        while true do
            local data, peer_host, peer_port = udp.recv(hb)
            if data and peer_host and peer_port then
                udp.send(hb, peer_host, peer_port, "ack:" .. data)
            end
        end
    end)

    -- TCP clients
    for i = 1, CLIENTS do
        lunet.spawn(function()
            local conn, cerr = socket.connect(HOST, TCP_PORT)
            if not conn then
                fail("connect failed for client " .. i .. ": " .. tostring(cerr))
            end
            local payload = "ping-" .. i
            if socket.write(conn, payload) then
                fail("write failed for client " .. i)
            end
            local resp, rerr = socket.read(conn)
            if resp ~= "pong:" .. payload then
                fail("client " .. i .. " bad reply: resp=" .. tostring(resp) .. " err=" .. tostring(rerr))
            end
            socket.close(conn)
            tcp_done = tcp_done + 1
            maybe_pass()
        end)
    end

    -- UDP heartbeat sender
    lunet.spawn(function()
        local h, err = udp.bind(HOST, 0)
        if not h then
            fail("udp.bind (sender) failed: " .. tostring(err))
        end
        lunet.spawn(function()
            while udp_acked < HBS do
                local data = udp.recv(h)
                if data then
                    udp_acked = udp_acked + 1
                end
            end
            maybe_pass()
        end)
        for i = 1, HBS do
            udp.send(h, HOST, UDP_PORT, "hb-" .. i)
            lunet.sleep(1)
        end
    end)

    -- Watchdog: a lost accept must fail fast, not hang.
    lunet.spawn(function()
        lunet.sleep(WATCHDOG_MS)
        if tcp_done ~= CLIENTS then
            fail("watchdog: only " .. tcp_done .. "/" .. CLIENTS ..
                " TCP clients completed (accepts=" .. accepts .. ")")
        end
        if udp_acked ~= HBS then
            fail("watchdog: only " .. udp_acked .. "/" .. HBS .. " UDP acks received")
        end
    end)
end)
