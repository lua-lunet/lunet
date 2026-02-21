local socket = require("lunet.socket")
local lunet = require("lunet")

local function test_bind_loopback()
  print("Testing bind to 127.0.0.1 (should succeed)...")
  local listener, err = socket.listen("tcp", "127.0.0.1", 19090)
  if not listener then
    print("FAIL: Failed to bind to 127.0.0.1: " .. (err or "unknown"))
    os.exit(1)
  end
  print("PASS: Bound to 127.0.0.1")
  socket.close(listener)
end

local function test_bind_public()
  print("Testing bind to 0.0.0.0 (should fail without flag)...")
  local listener, err = socket.listen("tcp", "0.0.0.0", 19091)
  if listener then
    print("FAIL: Successfully bound to 0.0.0.0 (Security violation!)")
    socket.close(listener)
    os.exit(1)
  end

  if string.find(err or "", "requires --dangerously", 1, true) then
    print("PASS: Rejected bind to 0.0.0.0: " .. err)
  else
    print("FAIL: Failed to bind but with unexpected error: " .. (err or "nil"))
    os.exit(1)
  end
end

lunet.spawn(function()
  test_bind_loopback()
  test_bind_public()
  print("All security tests passed!")
end)
