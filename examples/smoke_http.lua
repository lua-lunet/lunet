-- Minimal HTTP server for smoke testing
-- Serves static files from www/ directory
io.stdout:setvbuf('no')
local lunet = require("lunet")
local socket = require("lunet.socket")

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function handle_client(client)
    local data = socket.read(client)
    if not data then
        socket.close(client)
        return
    end

    local path = data:match("GET ([^ ]+)")
    if not path then
        socket.write(client, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
        socket.close(client)
        return
    end

    local file_path = "www" .. path
    local content = read_file(file_path)
    
    if content then
        local response = "HTTP/1.1 200 OK\r\n" ..
            "Content-Type: text/html\r\n" ..
            "Content-Length: " .. #content .. "\r\n" ..
            "Connection: close\r\n\r\n" .. content
        socket.write(client, response)
    else
        socket.write(client, "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
    end
    socket.close(client)
end

lunet.spawn(function()
    local listener, err = socket.listen("tcp", "127.0.0.1", 8080)
    if not listener then
        print("Failed to listen: " .. (err or "unknown error"))
        os.exit(1)
    end
    print("Smoke test server listening on http://127.0.0.1:8080")
    
    while true do
        local client = socket.accept(listener)
        if client then
            lunet.spawn(function()
                handle_client(client)
            end)
        end
    end
end)
