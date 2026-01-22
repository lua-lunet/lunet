--[[
  Stack Bug Detection Test
  
  This test specifically targets the lunet_ensure_coroutine() bug where
  lua_pushthread() is called but the thread is not popped on success.
  
  The bug causes:
  - Stack: [arg1, arg2] becomes [thread, arg1, arg2] after ensure_coroutine
  - When code reads arg1 from position 1, it gets thread instead
  - When code reads arg2 from position 2, it gets arg1 instead
  
  This test exercises functions that:
  1. Call lunet_ensure_coroutine()
  2. Then read arguments from specific stack positions
  
  With the bug present, fs.open("/path", "w") will:
  - Read position 1 expecting path, get thread
  - Read position 2 expecting mode, get "/path"
  - Fail with "invalid mode" or similar error
]]

local lunet = require("lunet")
local fs = require("lunet.fs")

local function log(msg)
  io.stderr:write(string.format("[BUG-TEST] %s\n", msg))
end

local function test_fs_open_args()
  log("Testing fs.open argument reading...")
  
  -- This is the exact pattern that triggers the bug
  -- fs.open calls lunet_ensure_coroutine(), then reads:
  --   path = luaL_checkstring(L, 1)
  --   mode = luaL_checkstring(L, 2)
  --
  -- With bug: stack is [thread, "/tmp/test.txt", "w"]
  --   position 1 = thread (not a string!) -> error
  --
  -- Without bug: stack is ["/tmp/test.txt", "w"]
  --   position 1 = path (correct)
  --   position 2 = mode (correct)
  
  local path = "/tmp/stack_bug_test.txt"
  local mode = "w"
  
  log(string.format("  Calling fs.open('%s', '%s')", path, mode))
  
  local fd, err = fs.open(path, mode)
  
  if err then
    log(string.format("  ERROR: %s", err))
    return false, err
  end
  
  log(string.format("  Got fd: %s", tostring(fd)))
  
  -- If we got here, arguments were read correctly
  fs.close(fd)
  os.remove(path)
  
  return true, nil
end

local function test_sleep_args()
  log("Testing lunet.sleep argument reading...")
  
  -- lunet.sleep calls lunet_ensure_coroutine(), then reads:
  --   ms = luaL_checkinteger(co, 1)
  --
  -- With bug: stack is [thread, 100]
  --   position 1 = thread (not an integer!) -> error
  --
  -- Without bug: stack is [100]
  --   position 1 = 100 (correct)
  
  local ms = 50
  log(string.format("  Calling lunet.sleep(%d)", ms))
  
  local start = os.clock()
  lunet.sleep(ms)
  local elapsed = (os.clock() - start) * 1000
  
  log(string.format("  Elapsed: %.1fms", elapsed))
  
  return true, nil
end

local function test_fs_write_args()
  log("Testing fs.write argument reading...")
  
  -- First open a file
  local path = "/tmp/stack_bug_write_test.txt"
  local fd, err = fs.open(path, "w")
  if err then
    return false, "setup failed: " .. err
  end
  
  -- fs.write calls lunet_ensure_coroutine(), then reads:
  --   fd = lua_tointeger(L, 1)
  --   data = luaL_checkstring(L, 2)
  --
  -- With bug: stack is [thread, fd, "data"]
  --   position 1 = thread (will be 0 when converted to integer)
  --   position 2 = fd (will try to write to wrong fd)
  --
  -- Without bug: stack is [fd, "data"]
  --   position 1 = fd (correct)
  --   position 2 = "data" (correct)
  
  local data = "Hello, World!"
  log(string.format("  Calling fs.write(%s, '%s')", tostring(fd), data))
  
  local written, err = fs.write(fd, data)
  
  if err then
    fs.close(fd)
    os.remove(path)
    return false, "write failed: " .. err
  end
  
  log(string.format("  Wrote %s bytes", tostring(written)))
  
  fs.close(fd)
  os.remove(path)
  
  return true, nil
end

-- Run all tests
log("===========================================")
log("  STACK BUG DETECTION TEST")
log("===========================================")
log("")
log("This test checks if lunet_ensure_coroutine()")
log("properly cleans up the Lua stack.")
log("")

local all_passed = true

lunet.spawn(function()
  local tests = {
    {"fs.open args", test_fs_open_args},
    {"lunet.sleep args", test_sleep_args},
    {"fs.write args", test_fs_write_args},
  }
  
  for _, test in ipairs(tests) do
    local name, func = test[1], test[2]
    log("")
    log(string.format("--- Test: %s ---", name))
    
    local ok, err = pcall(function()
      local success, msg = func()
      if not success then
        error(msg)
      end
    end)
    
    if ok then
      log(string.format("PASSED: %s", name))
    else
      log(string.format("FAILED: %s - %s", name, tostring(err)))
      all_passed = false
    end
  end
  
  log("")
  log("===========================================")
  if all_passed then
    log("  ALL TESTS PASSED")
    log("  Stack handling is correct!")
  else
    log("  TESTS FAILED")
    log("  Bug detected: lunet_ensure_coroutine()")
    log("  is leaving thread on stack!")
  end
  log("===========================================")
end)
