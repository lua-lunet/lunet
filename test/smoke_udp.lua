local lunet = require("lunet")
local udp = require("lunet.udp")

local host = "127.0.0.1"
local port = 19999

lunet.spawn(function()
  local s, err = udp.bind(host, port)
  if not s then
    print("bind failed: " .. err)
    os.exit(1)
  end
  print("bind success")
  
  -- Send to self
  local ok, err = udp.send(s, host, port, "hello")
  if not ok then
    print("send failed: " .. err)
    os.exit(1)
  end
  print("send success")

  local msg, rhost, rport = udp.recv(s)
  if not msg then
    print("recv failed")
    os.exit(1)
  end
  print("recv success: " .. msg)
  
  if msg ~= "hello" then
    print("msg mismatch")
    os.exit(1)
  end

  udp.close(s)
  print("close success")
  os.exit(0)
end)
