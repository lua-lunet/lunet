--[[
  Regression test: a coroutine looping on socket.accept must be resumed for
  every established TCP client while the same process runs concurrent UDP
  receive/heartbeat traffic.

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
local TCP_PORT = tonumber(os.getenv("TEST_TCP_PORT"))
local UDP_PORT = tonumber(os.getenv("TEST_UDP_PORT"))
local CLIENTS = tonumber(os.getenv("TEST_CLIENTS")) or 32
local HBS = tonumber(os.getenv("TEST_HBS")) or 200
local WATCHDOG_MS = tonumber(os.getenv("TEST_WATCHDOG_MS")) or 5000
local HEARTBEAT_WINDOW = math.min(32, HBS)

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

local function port_seed()
    -- os.clock() measures CPU time, which is close to zero at process
    -- startup and adds almost no entropy. Use os.time() (wall clock) so the
    -- seed actually varies across runs.
    local addr = tostring({}):match("0x(%x+)")
    local entropy = tonumber(addr, 16) or 0
    return 20000 + ((entropy + os.time()) % 30000)
end

local function bind_server_sockets()
    local function bind_udp(listener)
        local hb, herr = udp.bind(HOST, UDP_PORT or 0)
        if not hb then
            socket.close(listener)
            return nil, nil, nil, herr
        end
        local _, bound_udp_port, serr = udp.getsockname(hb)
        if not bound_udp_port then
            udp.close(hb)
            socket.close(listener)
            return nil, nil, nil, serr
        end
        return listener, hb, bound_udp_port, nil
    end

    if TCP_PORT then
        local listener, lerr = socket.listen("tcp", HOST, TCP_PORT)
        if not listener then
            return nil, nil, nil, nil, "listen failed: " .. tostring(lerr)
        end
        local bound_listener, hb, bound_udp_port, berr = bind_udp(listener)
        if not bound_listener then
            return nil, nil, nil, nil, "udp.bind failed: " .. tostring(berr)
        end
        return bound_listener, hb, TCP_PORT, bound_udp_port, nil
    end

    local start = port_seed()
    for attempt = 0, 127 do
        local tcp_port = 20000 + ((start + (attempt * 97)) % 30000)
        local listener = socket.listen("tcp", HOST, tcp_port)
        if listener then
            local bound_listener, hb, bound_udp_port, berr = bind_udp(listener)
            if bound_listener then
                return bound_listener, hb, tcp_port, bound_udp_port, nil
            end
            return nil, nil, nil, nil, "udp.bind failed: " .. tostring(berr)
        end
    end

    return nil, nil, nil, nil, "listen failed: unable to reserve a loopback TCP port"
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
    local listener, hb, tcp_port, udp_port, berr = bind_server_sockets()
    if not listener then
        fail(tostring(berr))
    end
    TCP_PORT = tcp_port
    UDP_PORT = udp_port

    -- Accept loop.
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

    -- UDP heartbeat responder.
    lunet.spawn(function()
        while true do
            local data, peer_host, peer_port = udp.recv(hb)
            if data and peer_host and peer_port then
                udp.send(hb, peer_host, peer_port, "ack:" .. data)
            end
        end
    end)

    -- TCP clients.
    for i = 1, CLIENTS do
        lunet.spawn(function()
            local conn, cerr = socket.connect(HOST, TCP_PORT)
            if not conn then
                fail("connect failed for client " .. i .. ": " .. tostring(cerr))
            end
            local payload = "ping-" .. i
            local werr = socket.write(conn, payload)
            if werr then
                fail("write failed for client " .. i .. ": " .. tostring(werr))
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

    -- UDP heartbeat sender.
    lunet.spawn(function()
        local h, err = udp.bind(HOST, 0)
        if not h then
            fail("udp.bind (sender) failed: " .. tostring(err))
        end
        local hb_sent = 0
        local function send_next_heartbeat()
            if hb_sent >= HBS then
                return
            end
            hb_sent = hb_sent + 1
            local ok, serr = udp.send(h, HOST, UDP_PORT, "hb-" .. hb_sent)
            if not ok then
                fail("udp.send failed for heartbeat " .. hb_sent .. ": " .. tostring(serr))
            end
        end
        lunet.spawn(function()
            while udp_acked < HBS do
                local data = udp.recv(h)
                if data then
                    udp_acked = udp_acked + 1
                    send_next_heartbeat()
                end
            end
            maybe_pass()
        end)
        for _ = 1, HEARTBEAT_WINDOW do
            send_next_heartbeat()
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
