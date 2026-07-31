#!/usr/bin/env lua
-- Config Generator for Advisory Lock CAS Demo
-- Discovers 4 free UDP ports and writes a Lua config file

local lunet = require("lunet")
local udp = require("lunet.udp")

local function parse_args()
    local output = ".tmp/advisory_lock_config.lua"
    local i = 1
    while i <= #arg do
        if arg[i] == "--output" and arg[i + 1] then
            output = arg[i + 1]
            i = i + 2
        else
            i = i + 1
        end
    end
    return output
end

local function discover_port()
    local h, err = udp.bind("127.0.0.1", 0)
    if not h then
        error("failed to bind ephemeral port: " .. tostring(err))
    end

    local host, port, gerr = udp.getsockname(h)
    if not host then
        udp.close(h)
        error("failed to getsockname: " .. tostring(gerr))
    end

    udp.close(h)

    if port <= 1024 then
        error("discovered port " .. port .. " is <= 1024")
    end

    return port
end

local function discover_unique_ports(count)
    local ports = {}
    local seen = {}
    local attempts = 0
    local max_attempts = count * 10

    while #ports < count and attempts < max_attempts do
        attempts = attempts + 1
        local port = discover_port()
        if not seen[port] then
            seen[port] = true
            ports[#ports + 1] = port
        end
    end

    if #ports < count then
        error("failed to discover " .. count .. " unique ports after " .. max_attempts .. " attempts")
    end

    return ports
end

local function write_config(output_path, ports)
    local dir = output_path:match("(.+)/[^/]+$")
    if dir then
        local quoted = "'" .. dir:gsub("'", "'\\''") .. "'"
        os.execute("mkdir -p " .. quoted)
    end

    local f, err = io.open(output_path, "w")
    if not f then
        error("failed to open output file: " .. tostring(err))
    end

    f:write("return {\n")
    f:write("  n1 = { client_port = " .. ports[1] .. ", peer_listen_port = " .. ports[2] .. ', host = "127.0.0.1" },\n')
    f:write("  n2 = { client_port = " .. ports[3] .. ", peer_listen_port = " .. ports[4] .. ', host = "127.0.0.1" }\n')
    f:write("}\n")

    f:close()
end

lunet.spawn(function()
    local output_path = parse_args()
    local ports = discover_unique_ports(4)
    write_config(output_path, ports)
    os.exit(0)
end)
