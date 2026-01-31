-- Unix socket test for lunet.unix extension module
-- This test verifies the Unix domain socket functionality.

local unix = require("lunet.unix")
local lunet = require("lunet")

local SOCKET_PATH = ".tmp/lunet_test.sock"

lunet.spawn(function()
  -- Ensure .tmp directory exists
  os.execute("mkdir -p .tmp")
  
  -- Clean up previous socket if exists
  unix.unlink(SOCKET_PATH)

  print("Testing Unix socket listen on " .. SOCKET_PATH)
  local listener, err = unix.listen(SOCKET_PATH)
  if not listener then
    print("FAIL: Failed to listen on Unix socket: " .. (err or "unknown"))
    os.exit(1)
  end
  print("PASS: Listening on Unix socket")

  -- Test connection
  lunet.spawn(function()
    print("Testing Unix socket connect...")
    local client, cerr = unix.connect(SOCKET_PATH)
    if not client then
      print("FAIL: Failed to connect: " .. (cerr or "unknown"))
      unix.close(listener)
      os.exit(1)
    end
    print("PASS: Connected to Unix socket")
    
    local werr = unix.write(client, "ping")
    if werr then
      print("FAIL: Write error: " .. werr)
      os.exit(1)
    end
    
    local data, rerr = unix.read(client)
    if rerr then
      print("FAIL: Read error: " .. rerr)
      os.exit(1)
    end
    if data ~= "pong" then
       print("FAIL: Expected 'pong', got " .. tostring(data))
       os.exit(1)
    end
    print("PASS: Read/Write verified")
    
    unix.close(client)
    unix.close(listener)
    
    -- Clean up socket file
    unix.unlink(SOCKET_PATH)
    
    print("All Unix socket tests passed!")
  end)

  -- Accept loop
  while true do
    local client = unix.accept(listener)
    if client then
      lunet.spawn(function()
        local data = unix.read(client)
        if data == "ping" then
          unix.write(client, "pong")
        end
        unix.close(client)
      end)
    else
        break
    end
  end
end)
