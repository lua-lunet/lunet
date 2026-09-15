local lunet = require("lunet")
local ws = require("lunet.websocket")

local HOST = "127.0.0.1"
local PORT = 18082

local function handle_conn(conn)
    while true do
        local msg, opcode, err = ws.recv(conn)
        if not msg then
            ws.close(conn, 1000, "bye")
            if err and err ~= "connection closed" then
                print("websocket recv ended:", err)
            end
            return
        end

        local ok, serr = ws.send(conn, msg, opcode)
        if not ok then
            print("websocket send failed:", serr or "unknown")
            ws.close(conn, 1011, "send failed")
            return
        end
    end
end

lunet.spawn(function()
    local listener, err = ws.listen("tcp", HOST, PORT, { registry = true })
    if not listener then
        print("Failed to listen:", err or "unknown")
        return
    end

    print("WebSocket echo server listening on ws://" .. HOST .. ":" .. PORT)
    print("Try: npx wscat -c ws://" .. HOST .. ":" .. PORT)

    while true do
        local conn, cerr = ws.accept(listener)
        if conn then
            lunet.spawn(function()
                handle_conn(conn)
            end)
        elseif cerr then
            print("accept failed:", cerr)
        end
    end
end)
