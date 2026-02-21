local socket = require("lunet.socket")
local lunet = require("lunet")

local SOCKET_PATH = ".tmp/stress.sock"
local CLIENTS = tonumber(os.getenv("STRESS_CLIENTS")) or 50
local MESSAGES = 100

lunet.spawn(function()
    os.remove(SOCKET_PATH)
    local listener = socket.listen("unix", SOCKET_PATH, 0)
    if not listener then error("Listen failed") end

    print("Server listening on " .. SOCKET_PATH)
    print("Spawning " .. CLIENTS .. " clients...")

    -- Accept loop
    lunet.spawn(function()
        while true do
            local client = socket.accept(listener)
            if client then
                lunet.spawn(function()
                    while true do
                        local data = socket.read(client)
                        if not data then break end
                        socket.write(client, data) -- Echo
                    end
                    socket.close(client)
                end)
            else
                break
            end
        end
    end)

    -- Clients
    local completed = 0
    for i = 1, CLIENTS do
        lunet.spawn(function()
            local client, err = socket.connect(SOCKET_PATH, 0)
            if not client then
                print("Connect failed client " .. i .. ": " .. (err or "unknown"))
                return
            end

            for _ = 1, MESSAGES do
                socket.write(client, "msg")
                local res = socket.read(client)
                if res ~= "msg" then
                    print("Mismatch data")
                    break
                end
            end
            socket.close(client)
            completed = completed + 1
            if completed % 10 == 0 then
                io.write(".")
                io.flush()
            end
            if completed == CLIENTS then
                print("\nAll clients completed successfully")
                socket.close(listener)
                os.exit(0)
            end
        end)
    end
end)
