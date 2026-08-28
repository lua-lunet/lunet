local lunet = require("lunet")
local socket = require("lunet.socket")
local ws = require("lunet.websocket")

local HOST = "127.0.0.1"
local PORT = 18083

local function handle_http(client)
    local body = "lunet http endpoint"
    local resp = "HTTP/1.1 200 OK\r\n" ..
        "Content-Type: text/plain\r\n" ..
        "Content-Length: " .. #body .. "\r\n\r\n" ..
        body
    socket.write(client, resp)
    socket.close(client)
end

local function handle_ws(conn)
    while true do
        local msg, opcode, err = ws.recv(conn)
        if not msg then
            ws.close(conn, 1000, "bye")
            return
        end
        local ok, serr = ws.send(conn, "echo:" .. msg, opcode)
        if not ok then
            ws.close(conn, 1011, serr or "send failed")
            return
        end
    end
end

local function read_request(client)
    local req, err = ws.read_http_request(client)
    if not req then
        return nil, err
    end
    return req, nil
end

lunet.spawn(function()
    local listener, err = socket.listen("tcp", HOST, PORT)
    if not listener then
        print("Failed to listen:", err or "unknown")
        return
    end

    print("Mixed HTTP/WS server listening on http://" .. HOST .. ":" .. PORT)
    print("HTTP test: curl http://" .. HOST .. ":" .. PORT)
    print("WS test:   npx wscat -c ws://" .. HOST .. ":" .. PORT)

    while true do
        local client, cerr = socket.accept(listener)
        if client then
            lunet.spawn(function()
                local req, rerr = read_request(client)
                if not req then
                    socket.close(client)
                    return
                end

                if ws.is_upgrade_request(req) then
                    local conn, uerr = ws.upgrade(client, req)
                    if not conn then
                        socket.write(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                        socket.close(client)
                        return
                    end
                    handle_ws(conn)
                else
                    handle_http(client)
                end
            end)
        elseif cerr then
            print("accept failed:", cerr)
        end
    end
end)
