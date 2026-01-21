local lunet = require("lunet")
local socket = require("lunet.socket")
local mysql = require("lunet.mysql")
local db_config = require("app.db_config")

print("Starting FULL STACK Debug Server on 8090...")

lunet.spawn(function()
    local listener, err = socket.listen("tcp", "0.0.0.0", 8090)
    if not listener then
        print("ERROR: Failed to listen: " .. (err or "unknown"))
        return
    end

    print("LISTENING: 0.0.0.0:8090")

    while true do
        local client, accept_err = socket.accept(listener)
        if client then
            lunet.spawn(function()
                print("--- Handling Request ---")
                
                -- 1. Read Request
                local data, read_err = socket.read(client)
                if not data then
                    print("READ ERROR: " .. (read_err or "nil"))
                    socket.close(client)
                    return
                end
                print("READ: Got " .. #data .. " bytes")
                
                -- 2. Connect to DB
                print("DB: Connecting...")
                local conn, db_err = mysql.open(db_config)
                if not conn then
                    print("DB ERROR: " .. (db_err or "unknown"))
                    local resp = "HTTP/1.1 500 Error\r\n\r\nDB Connect Failed: " .. (db_err or "")
                    socket.write(client, resp)
                    socket.close(client)
                    return
                end
                print("DB: Connected")

                -- 3. Insert Test Data
                local test_tag = "test_" .. os.time()
                print("DB: Inserting tag " .. test_tag)
                local res, exec_err = mysql.exec(conn, "INSERT INTO tags (name) VALUES ('" .. test_tag .. "')")
                if not res then
                     print("DB INSERT ERROR: " .. (exec_err or "unknown"))
                else
                     print("DB: Inserted ID: " .. (res.last_insert_id or "unknown"))
                end

                -- 4. Select Data
                print("DB: Selecting tags...")
                local rows, query_err = mysql.query(conn, "SELECT * FROM tags ORDER BY id DESC LIMIT 5")
                local body = "DB Test OK\n\nTags:\n"
                
                if rows then
                    for i, row in ipairs(rows) do
                        body = body .. "- " .. row.id .. ": " .. row.name .. "\n"
                    end
                else
                    body = body .. "Query failed: " .. (query_err or "unknown")
                end

                mysql.close(conn)
                print("DB: Closed")

                -- 5. Send Response
                local response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body
                socket.write(client, response)
                print("WRITE: Response sent")
                
                socket.close(client)
            end)
        end
    end
end)
