local socket = require("lunet.socket")
local lunet = require("lunet")

local SOCKET_PATH = ".tmp/lunet_test.sock"

lunet.spawn(function()
  -- Clean up previous socket if exists
  os.remove(SOCKET_PATH)

  print("Testing Unix socket listen on " .. SOCKET_PATH)
  local listener, listen_err = socket.listen("unix", SOCKET_PATH, 0)
  if not listener then
    print("FAIL: Failed to listen on Unix socket: " .. (listen_err or "unknown"))
    os.exit(1)
  end
  print("PASS: Listening on Unix socket")

  -- Test connection
  lunet.spawn(function()
    print("Testing Unix socket connect...")
    local client, err = socket.connect(SOCKET_PATH, 0) -- host is path, port ignored
    if not client then
      -- Try connecting with "unix" as first arg?
      -- The API is listen(protocol, host, port).
      -- connect(host, port) implies protocol is inferred or part of host?
      -- The README says: connect(host, port)
      -- My plan said: connect(host, port): Connect to remote server (tcp host/port, or unix path)
      -- So if I pass a path, it should detect it? Or should I change API to connect(protocol, ...)?
      -- Existing API is connect(host, port).
      -- If I pass path as host, how does it know?
      -- Maybe if it contains '/'? Or if port is 0?

      -- Wait, socket.connect signature in socket.c takes (host, port).
      -- I should probably overload it: if port is 0 and host looks like path?
      -- Or require "unix" prefix in host string? e.g. "unix:/tmp/s.sock"

      -- Let's check my plan: "API: socket.listen("unix", "/path/to/socket") - no port needed"
      -- "connect(host, port): ... (tcp host/port, or unix path)"

      print("FAIL: Failed to connect: " .. (err or "unknown"))
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
