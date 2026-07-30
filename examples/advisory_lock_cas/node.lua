#!/usr/bin/env lua
-- Node Process Skeleton for Advisory Lock CAS Demo
-- Parses CLI args, reads config, binds UDP sockets, signals readiness

local lunet = require("lunet")
local udp = require("lunet.udp")

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

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."

lunet.spawn(function()
    local role, config_path = parse_args()

    local config = dofile(config_path)
    if type(config) ~= "table" or type(config[role]) ~= "table" then
        io.stderr:write("Error: invalid config\n")
        os.exit(1)
    end

    local my = config[role]
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
        io.stderr:write("Error: failed to bind peer_listen_sock on " .. host .. ":" .. peer_listen_port .. ": " .. tostring(plerr) .. "\n")
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

    while true do
        lunet.sleep(1)
    end
end)
