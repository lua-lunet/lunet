local socket = require("lunet.socket")
local lunet = require("lunet")

local SOCKET_PATH = ".tmp/lunet_test.sock"

lunet.spawn(function()
  -- Clean up previous socket if exists
  os.remove(SOCKET_PATH)

  print("Testing Unix socket listen on " .. SOCKET_PATH)
  local listener, err = socket.listen("unix", SOCKET_PATH, 0)
  if not listener then
    print("FAIL: Failed to listen on Unix socket: " .. (err or "unknown"))
    os.exit(1)
  end
  print("PASS: Listening on Unix socket")

  -- Test connection
  lunet.spawn(function()
    print("Testing Unix socket connect...")
    local client, conn_err = socket.connect(SOCKET_PATH, 0) -- host is path, port ignored
    if not client then
      print("FAIL: Failed to connect: " .. (conn_err or "unknown"))
      socket.close(listener)
      os.exit(1)
    end
    print("PASS: Connected to Unix socket")

    socket.write(client, "ping")
    local data = socket.read(client)
    if data ~= "pong" then
       print("FAIL: Expected 'pong', got " .. tostring(data))
       os.exit(1)
    end
    print("PASS: Read/Write verified")

    socket.close(client)
    socket.close(listener)
    print("All Unix socket tests passed!")
  end)

  -- Accept loop
  while true do
    local client = socket.accept(listener)
    if client then
      lunet.spawn(function()
        local data = socket.read(client)
        if data == "ping" then
          socket.write(client, "pong")
        end
        socket.close(client)
      end)
    else
        break
    end
  end
end)