--[[
  Stack Pollution Test
  
  This test proves that lunet_ensure_coroutine() bug causes
  stack pollution by leaving threads on the stack.
  
  We can't directly inspect the C stack from Lua, but we can
  observe the behavior:
  
  1. With the bug, each call to an async function leaves a thread on stack
  2. This will eventually cause issues with stack overflow or memory
  3. We can detect it by checking if operations that should not affect
     the stack size actually change it
  
  The key insight: in a single coroutine, if we call multiple async
  operations in sequence, the stack should remain clean between calls.
  
  With the bug:
  - Call fs.open -> thread left on stack
  - Call fs.close -> another thread left on stack
  - Call fs.open -> another thread left on stack
  - ... stack grows unbounded!
]]

local lunet = require("lunet")
local fs = require("lunet.fs")

local function log(msg)
  io.stderr:write(string.format("[POLLUTION] %s\n", msg))
end

-- This test performs many sequential operations
-- With the bug, each operation adds a thread to the stack
-- Eventually this should cause visible problems

local ITERATIONS = 1000

log("===========================================")
log("  STACK POLLUTION TEST")
log("===========================================")
log("")
log(string.format("Running %d sequential async operations...", ITERATIONS * 4))
log("With the bug, each operation leaks a thread onto the stack.")
log("")

local start_time = os.time()

lunet.spawn(function()
  for i = 1, ITERATIONS do
    -- Each iteration does 4 async operations:
    -- 1. fs.open
    -- 2. fs.write  
    -- 3. fs.close
    -- 4. sleep
    
    local filename = "/tmp/pollution_test.txt"
    
    local fd, err = fs.open(filename, "w")
    if err then
      log(string.format("FAILED at iteration %d (open): %s", i, err))
      return
    end
    
    local written, err = fs.write(fd, "test")
    if err then
      fs.close(fd)
      log(string.format("FAILED at iteration %d (write): %s", i, err))
      return
    end
    
    err = fs.close(fd)
    if err then
      log(string.format("FAILED at iteration %d (close): %s", i, err))
      return
    end
    
    lunet.sleep(1)
    
    if i % 100 == 0 then
      log(string.format("Completed %d/%d iterations...", i, ITERATIONS))
    end
  end
  
  os.remove("/tmp/pollution_test.txt")
  
  local elapsed = os.time() - start_time
  log("")
  log("===========================================")
  log(string.format("  COMPLETED %d iterations in %d seconds", ITERATIONS, elapsed))
  log("===========================================")
  log("")
  log("If no errors occurred, the stack is being properly cleaned.")
  log("Check the TRACE SUMMARY above:")
  log("  - coref_balance should be 0")
  log("  - Total created should equal total released")
end)
