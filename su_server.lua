local socket = require "lunet.socket"
local su = require "lunet.su"
local lunet = require "lunet"

local function log(msg)
    local f = io.open("server.log", "a")
    if f then
        f:write(msg .. "\n")
        f:close()
    end
end

log("Starting server...")

-- Initialize Storage Unit
local data_file = "corfu.data"
local bitmap_file = "corfu.bitmap"
local max_blocks = 1024 * 1024 -- 1M blocks

log("Initializing Storage Unit...")
local ok, err = su.init(data_file, bitmap_file, max_blocks)
if not ok then
    log("Failed to init SU: " .. tostring(err))
    os.exit(1)
end
log("Storage Unit Initialized.")

local host = "0.0.0.0"
local port = 9000

lunet.spawn(function()
    log("Listening attempt...")
    local server_fd = socket.listen("tcp", host, port)
    if not server_fd then
        log("Failed to listen on " .. host .. ":" .. port)
        os.exit(1)
    end
    log("Listening on " .. host .. ":" .. port)

    while true do
        local client_fd = socket.accept(server_fd)
        if client_fd then
            log("Client connected")
            lunet.spawn(function()
                local buffer = ""
                local function read_bytes(n)
                    while #buffer < n do
                        local chunk = socket.read(client_fd)
                        if not chunk then return nil end
                        buffer = buffer .. chunk
                    end
                    local res = string.sub(buffer, 1, n)
                    buffer = string.sub(buffer, n + 1)
                    return res
                end

                -- Read 4 bytes length (Big Endian)
                local header = read_bytes(4)
                if not header then
                    socket.close(client_fd)
                    return
                end

                local b1, b2, b3, b4 = string.byte(header, 1, 4)
                local len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4

                -- Sanity check length
                if len > 1024 * 1024 then -- Limit script size to 1MB
                    socket.write(client_fd, "ERROR: Script too large")
                    socket.close(client_fd)
                    return
                end

                local script = read_bytes(len)
                if not script then
                    socket.close(client_fd)
                    return
                end
                
                log("Executing script of len " .. len)

                -- Sandbox environment
                local env = {
                    su = su,
                    print = log, -- Redirect print to log
                    tostring = tostring,
                    tonumber = tonumber,
                    string = string,
                    table = table,
                    pairs = pairs,
                    ipairs = ipairs
                }
                
                local chunk, load_err = loadstring(script)
                if not chunk then
                    socket.write(client_fd, "ERROR: Load failed: " .. tostring(load_err))
                    socket.close(client_fd)
                    return
                end
                
                setfenv(chunk, env)
                
                local status, result = pcall(chunk)
                if status then
                    socket.write(client_fd, "OK: " .. tostring(result))
                else
                    log("Script error: " .. tostring(result))
                    socket.write(client_fd, "ERROR: " .. tostring(result))
                end
                
                socket.close(client_fd)
            end)
        end
    end
end)
