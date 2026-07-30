#!/usr/bin/env lua
-- Node Process for Advisory Lock CAS Demo
-- Parses CLI args, reads config, binds UDP sockets, runs client and peer handlers

local lunet = require("lunet")
local udp = require("lunet.udp")

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local lock = dofile(script_dir .. "/lock.lua")
local codec = dofile(script_dir .. "/codec.lua")

local function usage()
    io.stderr:write("Usage: node.lua --hi|--lo <config_path>\n")
    os.exit(1)
end

local function parse_args()
    if #arg ~= 2 then usage() end
    local role_flag = arg[1]
    local config_path = arg[2]

    local role
    if role_flag == "--hi" then
        role = "hi"
    elseif role_flag == "--lo" then
        role = "lo"
    else
        io.stderr:write("Error: unknown flag '" .. role_flag .. "', expected --hi or --lo\n")
        os.exit(1)
    end

    return role, config_path
end

lunet.spawn(function()
    local role, config_path = parse_args()

    local config = dofile(config_path)
    if type(config) ~= "table" or type(config[role]) ~= "table" then
        io.stderr:write("Error: invalid config\n")
        os.exit(1)
    end

    local my = config[role]
    local peer_role = (role == "hi") and "lo" or "hi"
    local peer = config[peer_role]

    local client_port = my.client_port
    local peer_listen_port = my.peer_listen_port
    local host = my.host or "127.0.0.1"

    local client_sock, cerr = udp.bind(host, client_port)
    if not client_sock then
        io.stderr:write("Error: failed to bind client_sock on " .. host .. ":" .. client_port .. ": " .. tostring(cerr) .. "\n")
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

    local ready_path = ".tmp/advisory_lock_node_" .. role .. "_ready"
    local rf = io.open(ready_path, "w")
    if rf then
        rf:write("ready\n")
        rf:close()
    end

    print("READY role=" .. role .. " client_port=" .. client_port .. " peer_listen_port=" .. peer_listen_port)
    io.flush()

    local lock_table = lock.new()
    local peer_listen_port_remote = peer.peer_listen_port

    lunet.spawn(function()
        while true do
            local data, rhost, rport = udp.recv(client_sock)
            if not data then
                print("[" .. role .. "] client_handler: socket closed, exiting")
                break
            end

            local msg = codec.parse(data)
            if not msg then
                print("[" .. role .. "] client_handler: failed to parse message")
                goto continue
            end

            if msg.type == "GET" then
                local holder, token = lock.get(lock_table, msg.lock_id)
                local reply = codec.format_reply(msg.msg_id, "OK", holder, token)
                udp.send(client_sock, rhost, rport, reply)
                print("[" .. role .. "] client_handler GET lock=" .. msg.lock_id .. " result=ok holder=" .. holder)
            elseif msg.type == "SET" then
                local success, new_token = lock.cas(lock_table, msg.lock_id, msg.token, msg.holder)
                if not success then
                    local holder, _ = lock.get(lock_table, msg.lock_id)
                    local reply = codec.format_reply(msg.msg_id, "CONFLICT", holder, new_token)
                    udp.send(client_sock, rhost, rport, reply)
                    print("[" .. role .. "] client_handler SET lock=" .. msg.lock_id .. " result=conflict (local)")
                    goto continue
                end

                local peer_msg = codec.format_peer("PEER_SET", msg.lock_id, msg.token, msg.holder, msg.msg_id)
                udp.send(peer_sock, host, peer_listen_port_remote, peer_msg)

                local peer_data, _, _ = udp.recv(peer_sock)
                local peer_reply = peer_data and codec.parse(peer_data)

                if peer_reply and peer_reply.status == "OK" then
                    local reply = codec.format_reply(msg.msg_id, "OK", msg.holder, new_token)
                    udp.send(client_sock, rhost, rport, reply)
                    print("[" .. role .. "] client_handler SET lock=" .. msg.lock_id .. " result=ok (peer confirmed)")
                else
                    if peer_reply then
                        lock_table[msg.lock_id] = { holder = peer_reply.holder, token = peer_reply.token }
                        local reply = codec.format_reply(msg.msg_id, "CONFLICT", peer_reply.holder, peer_reply.token)
                        udp.send(client_sock, rhost, rport, reply)
                        print("[" .. role .. "] client_handler SET lock=" .. msg.lock_id
                            .. " result=conflict (peer disagreed)")
                    else
                        local reply = codec.format_reply(msg.msg_id, "CONFLICT", 0, 0)
                        udp.send(client_sock, rhost, rport, reply)
                        print("[" .. role .. "] client_handler SET lock=" .. msg.lock_id
                            .. " result=conflict (peer no reply)")
                    end
                end
            else
                print("[" .. role .. "] client_handler: unknown message type: " .. tostring(msg.type))
            end

            ::continue::
        end
    end)

    lunet.spawn(function()
        while true do
            local data, rhost, rport = udp.recv(peer_listen_sock)
            if not data then
                print("[" .. role .. "] peer_handler: socket closed, exiting")
                break
            end

            local msg = codec.parse(data)
            if not msg then
                print("[" .. role .. "] peer_handler: failed to parse message")
                goto continue
            end

            if msg.type == "PEER_GET" then
                local holder, token = lock.get(lock_table, msg.lock_id)
                local reply = codec.format_reply(msg.msg_id, "OK", holder, token)
                udp.send(peer_listen_sock, rhost, rport, reply)
                print("[" .. role .. "] peer_handler PEER_GET lock=" .. msg.lock_id .. " result=ok holder=" .. holder)
            elseif msg.type == "PEER_SET" then
                local success, new_token = lock.cas(lock_table, msg.lock_id, msg.token, msg.holder)
                if success then
                    local reply = codec.format_reply(msg.msg_id, "OK", msg.holder, new_token)
                    udp.send(peer_listen_sock, rhost, rport, reply)
                    print("[" .. role .. "] peer_handler PEER_SET lock=" .. msg.lock_id .. " result=ok")
                else
                    local holder, _ = lock.get(lock_table, msg.lock_id)
                    local reply = codec.format_reply(msg.msg_id, "CONFLICT", holder, new_token)
                    udp.send(peer_listen_sock, rhost, rport, reply)
                    print("[" .. role .. "] peer_handler PEER_SET lock=" .. msg.lock_id .. " result=conflict")
                end
            else
                print("[" .. role .. "] peer_handler: unknown message type: " .. tostring(msg.type))
            end

            ::continue::
        end
    end)
end)
