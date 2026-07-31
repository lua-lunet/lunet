#!/usr/bin/env lua
-- Node Process for Advisory Lock CAS Demo (item16 rework)
--
-- Write ordering (S1/S2): every write traverses HIGH before LOW. The HIGH
-- node is the single serializer: it CASes locally and propagates every
-- committed write to the LOW node. The LOW node never applies client SETs
-- locally; it forwards them to HIGH and relays the reply. All of LOW's
-- state changes arrive via HIGH's propagation (its peer_listen handler).
--
-- Correlation (S4): one dispatcher coroutine owns udp.recv(peer_sock) and
-- delivers REPLYs into a pending table keyed by msg_id. Workers never
-- recv on peer_sock directly.
--
-- Timeouts (BUG-3): every peer wait is bounded and retried. On
-- propagation timeout HIGH performs a CAS-guarded rollback of the
-- unpropagated write and answers UNAVAILABLE.
--
-- Liveness (S5): the blocking graph is a DAG — only LOW's peer_listen
-- handler never awaits the network (terminal). Bounded waits and bounded
-- retries: no deadlock, no livelock.

io.stdout:setvbuf("line")

local lunet = require("lunet")
local udp = require("lunet.udp")

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local lock = dofile(script_dir .. "/lock.lua")
local codec = dofile(script_dir .. "/codec.lua")
local pending_mod = dofile(script_dir .. "/pending.lua")

local PROP_TIMEOUT_MS = 250
local PROP_ATTEMPTS = 5
local FWD_TIMEOUT_MS = 500
local FWD_ATTEMPTS = 3

local function usage()
    io.stderr:write("Usage: node.lua <config_path> <n1|n2>\n")
    os.exit(1)
end

local function parse_args()
    if #arg ~= 2 then usage() end
    local config_path = arg[1]
    local label = arg[2]
    if label ~= "n1" and label ~= "n2" then
        io.stderr:write("Error: unknown label '" .. label .. "', expected n1 or n2\n")
        os.exit(1)
    end
    return config_path, label
end

local function ip_num(ip)
    local n = 0
    for oct in tostring(ip):gmatch("%d+") do
        n = n * 256 + tonumber(oct)
    end
    return n
end

lunet.spawn(function()
    local config_path, label = parse_args()

    local config = dofile(config_path)
    if type(config) ~= "table" or type(config[label]) ~= "table" then
        io.stderr:write("Error: invalid config\n")
        os.exit(1)
    end

    local my = config[label]
    local peer_label = (label == "n1") and "n2" or "n1"
    local peer = config[peer_label]

    local client_port = my.client_port
    local peer_listen_port = my.peer_listen_port
    local host = my.host or "127.0.0.1"

    local client_sock, cerr = udp.bind(host, client_port)
    if not client_sock then
        io.stderr:write("Error: failed to bind client_sock on "
            .. host .. ":" .. client_port .. ": "
            .. tostring(cerr) .. "\n")
        os.exit(1)
    end

    local peer_sock, perr = udp.bind(host, 0)
    if not peer_sock then
        io.stderr:write("Error: failed to bind peer_sock: " .. tostring(perr) .. "\n")
        udp.close(client_sock)
        os.exit(1)
    end

    local peer_listen_sock, plerr = udp.bind(host, peer_listen_port)
    if not peer_listen_sock then
        io.stderr:write("Error: failed to bind peer_listen_sock on "
            .. host .. ":" .. peer_listen_port .. ": "
            .. tostring(plerr) .. "\n")
        udp.close(client_sock)
        udp.close(peer_sock)
        os.exit(1)
    end

    -- S1: derive the write order from the client-facing addresses.
    local own_host, own_port, gerr = udp.getsockname(client_sock)
    if not own_host then
        io.stderr:write("Error: getsockname failed: " .. tostring(gerr) .. "\n")
        os.exit(1)
    end
    local peer_host = peer.host or "127.0.0.1"
    local order
    if ip_num(own_host) ~= ip_num(peer_host) then
        order = (ip_num(own_host) > ip_num(peer_host)) and "HIGH" or "LOW"
    elseif own_port ~= peer.client_port then
        order = (own_port > peer.client_port) and "HIGH" or "LOW"
    else
        io.stderr:write("Error: identical client addresses; cannot derive order\n")
        os.exit(1)
    end

    local logprefix = "[" .. label .. "/" .. order .. "]"

    local ready_path = ".tmp/advisory_lock_node_" .. label .. "_ready"
    local rf = io.open(ready_path, "w")
    if rf then
        rf:write("ready\n")
        rf:close()
    end

    print("READY label=" .. label .. " order=" .. order
        .. " client=" .. own_host .. ":" .. own_port
        .. " peer_listen_port=" .. peer_listen_port)

    -- Shared state (cooperative coroutines: no preemption between yields).
    local lock_table = lock.new()
    local pend = pending_mod.new()
    local peer_seq = 0
    local peer_target_port = peer.peer_listen_port

    local function next_msg_id()
        peer_seq = peer_seq + 1
        return string.format("%08x", peer_seq)
    end

    -- HIGH -> LOW: propagate a committed transition (expected_token ->
    -- new_holder). Awaits LOW's apply-OK. Retries the SAME transition on
    -- CONFLICT (LOW is missing an earlier propagation; it will land first
    -- on loopback). Never adopts LOW's value. Returns "OK" or "TIMEOUT".
    local function propagate(lock_id, expected_token, new_holder, what)
        for _ = 1, PROP_ATTEMPTS do
            local mid = next_msg_id()
            local w = pend.register(mid)
            udp.send(peer_sock, host, peer_target_port,
                codec.format_peer("PEER_SET", lock_id, expected_token, new_holder, mid))
            local reply, timed_out = pend.wait(w, PROP_TIMEOUT_MS)
            if not timed_out and reply.status == "OK" then
                return "OK"
            end
        end
        print(logprefix .. " " .. what .. " lock=" .. lock_id .. " propagation TIMEOUT")
        return "TIMEOUT"
    end

    -- Guarded rollback of a committed-but-unpropagated write.
    local function rollback(lock_id, new_token, old_holder, what)
        local ok = lock.cas(lock_table, lock_id, new_token, old_holder)
        if not ok then
            print(logprefix .. " " .. what .. " lock=" .. lock_id
                .. " rollback SKIPPED: lock advanced by another writer")
        end
    end

    -- ── reply dispatcher: sole owner of udp.recv(peer_sock) ─────────────
    lunet.spawn(function()
        while true do
            local data = udp.recv(peer_sock)
            if not data then
                print(logprefix .. " dispatcher: socket closed, exiting")
                break
            end
            local msg = codec.parse(data)
            if msg and msg.type == "REPLY" then
                if not pend.deliver(msg.msg_id, msg) then
                    print(logprefix .. " dispatcher: dropping reply for unknown msg_id "
                        .. tostring(msg.msg_id))
                end
            else
                print(logprefix .. " dispatcher: unparsed datagram dropped")
            end
        end
    end)

    -- ── client handler ──
    lunet.spawn(function()
        while true do
            local data, rhost, rport = udp.recv(client_sock)
            if not data then
                print(logprefix .. " client_handler: socket closed, exiting")
                break
            end

            local msg = codec.parse(data)
            if not msg then
                print(logprefix .. " client_handler: failed to parse message")
                goto continue
            end

            if msg.type == "GET" then
                local holder, token = lock.get(lock_table, msg.lock_id)
                udp.send(client_sock, rhost, rport,
                    codec.format_reply(msg.msg_id, "OK", holder, token))
                print(logprefix .. " client_handler GET lock=" .. msg.lock_id
                    .. " holder=" .. holder)

            elseif msg.type == "SET" then
                if msg.holder == 0 then
                    udp.send(client_sock, rhost, rport,
                        codec.format_reply(msg.msg_id, "INVALID"))
                    print(logprefix .. " client_handler SET lock=" .. msg.lock_id
                        .. " result=invalid (holder=0)")
                    goto continue
                end

                if order == "HIGH" then
                    local old_holder = lock.get(lock_table, msg.lock_id)
                    local success, new_token = lock.cas(lock_table, msg.lock_id,
                        msg.token, msg.holder)
                    if not success then
                        local holder, cur_token = lock.get(lock_table, msg.lock_id)
                        udp.send(client_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "CONFLICT", holder, cur_token))
                        print(logprefix .. " client_handler SET lock=" .. msg.lock_id
                            .. " result=conflict (local)")
                        goto continue
                    end
                    local r = propagate(msg.lock_id, msg.token, msg.holder, "client_handler SET")
                    if r == "OK" then
                        udp.send(client_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "OK", msg.holder, new_token))
                        print(logprefix .. " client_handler SET lock=" .. msg.lock_id
                            .. " result=ok holder=" .. msg.holder)
                    else
                        rollback(msg.lock_id, new_token, old_holder, "client_handler SET")
                        udp.send(client_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "UNAVAILABLE"))
                        print(logprefix .. " client_handler SET lock=" .. msg.lock_id
                            .. " result=unavailable (peer timeout, rolled back)")
                    end
                else
                    -- LOW: forward to HIGH, relay the reply. Never write locally.
                    local answered = nil
                    for _ = 1, FWD_ATTEMPTS do
                        local mid = next_msg_id()
                        local w = pend.register(mid)
                        udp.send(peer_sock, host, peer_target_port,
                            codec.format_peer("PEER_SET", msg.lock_id, msg.token,
                                msg.holder, mid))
                        local reply, timed_out = pend.wait(w, FWD_TIMEOUT_MS)
                        if not timed_out then
                            answered = reply
                            break
                        end
                    end
                    if answered and answered.status == "OK" then
                        udp.send(client_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "OK",
                                answered.holder, answered.token))
                        print(logprefix .. " client_handler SET lock=" .. msg.lock_id
                            .. " result=ok (via HIGH)")
                    elseif answered and answered.status == "CONFLICT" then
                        udp.send(client_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "CONFLICT",
                                answered.holder, answered.token))
                        print(logprefix .. " client_handler SET lock=" .. msg.lock_id
                            .. " result=conflict (via HIGH)")
                    else
                        udp.send(client_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "UNAVAILABLE"))
                        print(logprefix .. " client_handler SET lock=" .. msg.lock_id
                            .. " result=unavailable (HIGH timeout)")
                    end
                end
            else
                print(logprefix .. " client_handler: unknown message type: "
                    .. tostring(msg.type))
            end

            ::continue::
        end
    end)

    -- ── peer_listen handler ──
    lunet.spawn(function()
        while true do
            local data, rhost, rport = udp.recv(peer_listen_sock)
            if not data then
                print(logprefix .. " peer_handler: socket closed, exiting")
                break
            end

            local msg = codec.parse(data)
            if not msg then
                print(logprefix .. " peer_handler: failed to parse message")
                goto continue
            end

            if msg.type == "PEER_GET" then
                local holder, token = lock.get(lock_table, msg.lock_id)
                udp.send(peer_listen_sock, rhost, rport,
                    codec.format_reply(msg.msg_id, "OK", holder, token))
                print(logprefix .. " peer_handler PEER_GET lock=" .. msg.lock_id
                    .. " holder=" .. holder)

            elseif msg.type == "PEER_SET" then
                if order == "HIGH" then
                    -- Forwarded client write from LOW: serialize here.
                    local old_holder = lock.get(lock_table, msg.lock_id)
                    local success, new_token = lock.cas(lock_table, msg.lock_id,
                        msg.token, msg.holder)
                    if not success then
                        local holder, cur_token = lock.get(lock_table, msg.lock_id)
                        udp.send(peer_listen_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "CONFLICT", holder, cur_token))
                        print(logprefix .. " peer_handler PEER_SET lock=" .. msg.lock_id
                            .. " result=conflict (forwarded)")
                        goto continue
                    end
                    -- Propagate to LOW so its state is durable before the
                    -- client is told.
                    local r = propagate(msg.lock_id, msg.token, msg.holder,
                        "peer_handler PEER_SET(fwd)")
                    if r == "OK" then
                        udp.send(peer_listen_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "OK", msg.holder, new_token))
                        print(logprefix .. " peer_handler PEER_SET lock=" .. msg.lock_id
                            .. " result=ok (forwarded, propagated)")
                    else
                        rollback(msg.lock_id, new_token, old_holder, "peer_handler PEER_SET")
                        udp.send(peer_listen_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "UNAVAILABLE"))
                        print(logprefix .. " peer_handler PEER_SET lock=" .. msg.lock_id
                            .. " result=unavailable (propagation timeout, rolled back)")
                    end
                else
                    -- LOW: authoritative propagation from HIGH. Apply and
                    -- reply. Terminal handler: never awaits the network.
                    -- Idempotent: a duplicate/late PEER_SET for a state we
                    -- already hold is an OK, not a conflict.
                    local success, new_token = lock.cas(lock_table, msg.lock_id,
                        msg.token, msg.holder)
                    if success then
                        udp.send(peer_listen_sock, rhost, rport,
                            codec.format_reply(msg.msg_id, "OK", msg.holder, new_token))
                        print(logprefix .. " peer_handler PEER_SET lock=" .. msg.lock_id
                            .. " result=ok (applied propagation)")
                    else
                        local holder, cur_token = lock.get(lock_table, msg.lock_id)
                        if cur_token == lock.pack_token(msg.lock_id, msg.holder) then
                            udp.send(peer_listen_sock, rhost, rport,
                                codec.format_reply(msg.msg_id, "OK", holder, cur_token))
                            print(logprefix .. " peer_handler PEER_SET lock=" .. msg.lock_id
                                .. " result=ok (duplicate propagation, idempotent)")
                        else
                            udp.send(peer_listen_sock, rhost, rport,
                                codec.format_reply(msg.msg_id, "CONFLICT", holder, cur_token))
                            print(logprefix .. " peer_handler PEER_SET lock=" .. msg.lock_id
                                .. " result=conflict (propagation out of order)")
                        end
                    end
                end
            else
                print(logprefix .. " peer_handler: unknown message type: "
                    .. tostring(msg.type))
            end

            ::continue::
        end
    end)
end)
