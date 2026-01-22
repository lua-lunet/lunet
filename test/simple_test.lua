-- Simple test to verify basic functionality
local lunet = require("lunet")
local fs = require("lunet.fs")

print("[TEST] Starting simple trace test...")

-- Test timer
lunet.spawn(function()
  print("[TEST] Timer: sleeping 100ms...")
  lunet.sleep(100)
  print("[TEST] Timer: done!")
end)

-- Test fs
lunet.spawn(function()
  local filename = "/tmp/lunet_simple_test.txt"
  
  -- Write
  print("[TEST] FS: writing file...")
  local fd, err = fs.open(filename, "w")
  if err then error("open failed: " .. err) end
  
  local written, err = fs.write(fd, "Hello from lunet trace test!\n")
  if err then error("write failed: " .. err) end
  
  err = fs.close(fd)
  if err then error("close failed: " .. err) end
  
  -- Read
  print("[TEST] FS: reading file...")
  fd, err = fs.open(filename, "r")
  if err then error("open failed: " .. err) end
  
  local data, err = fs.read(fd, 1024)
  if err then error("read failed: " .. err) end
  
  err = fs.close(fd)
  if err then error("close failed: " .. err) end
  
  print("[TEST] FS: read data: " .. data:gsub("\n", ""))
  
  -- Cleanup
  os.remove(filename)
  print("[TEST] FS: done!")
end)

-- Completion
lunet.spawn(function()
  lunet.sleep(200)
  print("[TEST] All tests completed!")
end)

print("[TEST] Tests started, waiting...")
