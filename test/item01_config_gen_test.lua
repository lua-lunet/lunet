#!/usr/bin/env lua
-- Test for Item 01: Config Generator
-- Tests that config_gen.lua discovers ports and writes valid Lua config

local lunet = require("lunet")
local udp = require("lunet.udp")

local function test_config_gen()
    local output_path = ".tmp/test_advisory_lock_config.lua"
    local script_path = "examples/advisory_lock_cas/config_gen.lua"

    -- Clean up any existing output
    os.remove(output_path)

    -- Run config_gen.lua
    local cmd = string.format("./build/macosx/arm64/release/lunet-run %s --output %s", script_path, output_path)
    local exit_code = os.execute(cmd)

    -- Check exit code
    if exit_code ~= 0 then
        io.stderr:write("FAIL: config_gen.lua exited with code " .. tostring(exit_code) .. "\n")
        os.exit(1)
    end

    -- Check output file exists
    local f = io.open(output_path, "r")
    if not f then
        io.stderr:write("FAIL: output file does not exist at " .. output_path .. "\n")
        os.exit(1)
    end
    f:close()

    -- Load the config via dofile
    local config = dofile(output_path)
    if type(config) ~= "table" then
        io.stderr:write("FAIL: config is not a table\n")
        os.exit(1)
    end

    -- Check structure
    if type(config.n1) ~= "table" then
        io.stderr:write("FAIL: config.n1 is not a table\n")
        os.exit(1)
    end
    if type(config.n2) ~= "table" then
        io.stderr:write("FAIL: config.n2 is not a table\n")
        os.exit(1)
    end

    -- Check required fields exist
    local required_fields = {"client_port", "peer_listen_port", "host"}
    for _, field in ipairs(required_fields) do
        if config.n1[field] == nil then
            io.stderr:write("FAIL: config.n1." .. field .. " is nil\n")
            os.exit(1)
        end
        if config.n2[field] == nil then
            io.stderr:write("FAIL: config.n2." .. field .. " is nil\n")
            os.exit(1)
        end
    end

    -- Check ports are integers > 1024
    local ports = {
        config.n1.client_port,
        config.n1.peer_listen_port,
        config.n2.client_port,
        config.n2.peer_listen_port
    }

    for i, port in ipairs(ports) do
        if type(port) ~= "number" then
            io.stderr:write("FAIL: port " .. i .. " is not a number\n")
            os.exit(1)
        end
        if math.floor(port) ~= port then
            io.stderr:write("FAIL: port " .. i .. " is not an integer\n")
            os.exit(1)
        end
        if port <= 1024 then
            io.stderr:write("FAIL: port " .. i .. " is <= 1024 (got " .. port .. ")\n")
            os.exit(1)
        end
    end

    -- Check all 4 ports are different
    local seen = {}
    for _, port in ipairs(ports) do
        if seen[port] then
            io.stderr:write("FAIL: duplicate port " .. port .. "\n")
            os.exit(1)
        end
        seen[port] = true
    end

    -- Check host is "127.0.0.1"
    if config.n1.host ~= "127.0.0.1" then
        io.stderr:write("FAIL: config.n1.host is not '127.0.0.1' (got '" .. tostring(config.n1.host) .. "')\n")
        os.exit(1)
    end
    if config.n2.host ~= "127.0.0.1" then
        io.stderr:write("FAIL: config.n2.host is not '127.0.0.1' (got '" .. tostring(config.n2.host) .. "')\n")
        os.exit(1)
    end

    -- Verify ports are actually free (can bind to them)
    lunet.spawn(function()
    for _, port in ipairs(ports) do
            local h, err = udp.bind("127.0.0.1", port)
            if not h then
                io.stderr:write("FAIL: port " .. port .. " is not free: " .. tostring(err) .. "\n")
                os.exit(1)
            end
            udp.close(h)
        end
    end)

    print("PASS: all config_gen tests passed")
    os.exit(0)
end

test_config_gen()
