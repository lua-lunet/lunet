--[[
  Stress Test for Coroutine Reference Bug Detection
  
  This test exercises the lunet_ensure_coroutine() bug where a thread
  is left on the Lua stack. The bug manifests when:
  
  1. lunet_ensure_coroutine() is called (pushes thread, doesn't pop on success)
  2. Code tries to read arguments from expected stack positions
  3. Arguments are off by 1 because of the extra thread on stack
  
  With the bug present, operations will either:
  - Fail with wrong argument types
  - Produce incorrect results
  - Crash
  
  Run with:
    cmake -DLUNET_TRACE=ON -DCMAKE_BUILD_TYPE=Debug ..
    make
    ./lunet test/stress_test.lua
]]

local lunet = require("lunet")
local fs = require("lunet.fs")

local ITERATIONS = 100
local CONCURRENCY = 10

local passed = 0
local failed = 0
local errors = {}

local function log(msg)
  io.stderr:write(string.format("[STRESS] %s\n", msg))
end

-- Test that exercises fs.open with specific arguments
-- The bug will cause the path argument to be read from wrong position
local function test_fs_open_close()
  local filename = "/tmp/stress_test_" .. tostring(math.random(100000)) .. ".txt"
  
  -- This should work: fs.open(path, mode)
  -- With the bug: stack has [thread, path, mode] instead of [path, mode]
  -- So fs.open sees thread as path, path as mode
  local fd, err = fs.open(filename, "w")
  if err then
    return false, "fs.open failed: " .. tostring(err)
  end
  
  -- Write something
  local written, err = fs.write(fd, "test data")
  if err then
    fs.close(fd)
    return false, "fs.write failed: " .. tostring(err)
  end
  
  -- Close
  err = fs.close(fd)
  if err then
    return false, "fs.close failed: " .. tostring(err)
  end
  
  -- Cleanup
  os.remove(filename)
  return true, nil
end

-- Test that exercises timer with specific duration
-- The bug will cause duration to be read from wrong position
local function test_sleep()
  local start = os.clock()
  lunet.sleep(10)  -- 10ms
  local elapsed = (os.clock() - start) * 1000
  
  -- Should be roughly 10ms (allow for scheduling variance)
  if elapsed < 0 or elapsed > 1000 then
    return false, string.format("sleep timing wrong: expected ~10ms, got %.2fms", elapsed)
  end
  
  return true, nil
end

-- Test rapid sequential operations
-- This maximizes chances of hitting the stack corruption
local function test_rapid_operations()
  for i = 1, 10 do
    lunet.sleep(1)
    
    local filename = "/tmp/rapid_test_" .. tostring(i) .. ".txt"
    local fd, err = fs.open(filename, "w")
    if err then
      return false, "rapid open failed at iteration " .. i .. ": " .. tostring(err)
    end
    
    local written, err = fs.write(fd, "iteration " .. i)
    if err then
      fs.close(fd)
      return false, "rapid write failed at iteration " .. i .. ": " .. tostring(err)
    end
    
    err = fs.close(fd)
    if err then
      return false, "rapid close failed at iteration " .. i .. ": " .. tostring(err)
    end
    
    os.remove(filename)
  end
  
  return true, nil
end

-- Run a single test iteration
local function run_test(id, test_func, test_name)
  lunet.spawn(function()
    local ok, err = test_func()
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      table.insert(errors, string.format("[%d] %s: %s", id, test_name, err))
    end
  end)
end

-- Main test driver
log("===========================================")
log("  STRESS TEST - Bug Detection")
log("===========================================")
log(string.format("Running %d iterations with %d concurrency", ITERATIONS, CONCURRENCY))
log("")

-- Launch concurrent test workers
for i = 1, CONCURRENCY do
  lunet.spawn(function()
    for j = 1, ITERATIONS do
      local test_id = (i - 1) * ITERATIONS + j
      
      -- Run different test types
      if j % 3 == 0 then
        run_test(test_id, test_fs_open_close, "fs_open_close")
      elseif j % 3 == 1 then
        run_test(test_id, test_sleep, "sleep")
      else
        run_test(test_id, test_rapid_operations, "rapid_ops")
      end
      
      -- Small delay between iterations
      lunet.sleep(5)
    end
  end)
end

-- Wait for completion and report
lunet.spawn(function()
  -- Wait for all tests to complete (with timeout)
  local expected = ITERATIONS * CONCURRENCY
  local max_wait = 60000  -- 60 seconds
  local waited = 0
  
  while (passed + failed) < expected and waited < max_wait do
    lunet.sleep(100)
    waited = waited + 100
    
    if waited % 5000 == 0 then
      log(string.format("Progress: %d/%d completed (%d passed, %d failed)", 
                        passed + failed, expected, passed, failed))
    end
  end
  
  log("")
  log("===========================================")
  log("  STRESS TEST RESULTS")
  log("===========================================")
  log(string.format("Total tests: %d", passed + failed))
  log(string.format("Passed:      %d", passed))
  log(string.format("Failed:      %d", failed))
  log("")
  
  if #errors > 0 then
    log("Errors (first 10):")
    for i = 1, math.min(10, #errors) do
      log("  " .. errors[i])
    end
    if #errors > 10 then
      log(string.format("  ... and %d more errors", #errors - 10))
    end
  end
  
  log("")
  if failed > 0 then
    log("STRESS TEST FAILED - Bug detected!")
    log("")
    log("Check trace output above for coref_balance != 0")
  else
    log("STRESS TEST PASSED")
    log("")
    log("Check trace output - coref_balance should be 0")
  end
end)

log("Tests started...")
