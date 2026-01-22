--[[
  Comprehensive Trace Test
  
  This test exercises all code paths that use coroutine references:
  - Timer (sleep)
  - File system (open, read, write, close, stat, scandir)
  - Socket (listen, accept, read, write, connect, close)
  
  Run with tracing enabled to verify all refs are properly balanced:
    cmake -DLUNET_TRACE=ON -DCMAKE_BUILD_TYPE=Debug ..
    make
    ./lunet test/trace_test.lua
  
  At shutdown, trace should show:
    - coref_balance = 0
    - All refs balanced
]]

local lunet = require("lunet")
local fs = require("lunet.fs")
local socket = require("lunet.socket")

-- Test configuration
local TEST_PORT = tonumber(os.getenv("TEST_PORT")) or 18080
local TEST_DIR = "/tmp/lunet_trace_test"
local CONCURRENCY = 5
local ITERATIONS = 3

-- Utility functions
local function log(msg)
  io.stderr:write(string.format("[TEST] %s\n", msg))
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

-- Track completion of concurrent operations
local completed = {
  timers = 0,
  fs_ops = 0,
  socket_ops = 0,
  clients = 0,
}

--------------------------------------------------------------------------------
-- Timer Tests
--------------------------------------------------------------------------------
local function test_timers()
  log("Starting timer tests...")
  
  for i = 1, CONCURRENCY do
    lunet.spawn(function()
      -- Multiple sleeps to exercise coref create/release cycle
      lunet.sleep(10)
      lunet.sleep(5)
      lunet.sleep(1)
      completed.timers = completed.timers + 1
      log(string.format("Timer %d completed", i))
    end)
  end
end

--------------------------------------------------------------------------------
-- File System Tests
--------------------------------------------------------------------------------
local function test_fs()
  log("Starting FS tests...")
  
  -- Create test directory
  os.execute("mkdir -p " .. TEST_DIR)
  
  for i = 1, CONCURRENCY do
    lunet.spawn(function()
      local filename = string.format("%s/test_%d.txt", TEST_DIR, i)
      local content = string.format("Test content for file %d - iteration data\n", i)
      
      for iter = 1, ITERATIONS do
        -- Open file for writing
        local fd, err = fs.open(filename, "w")
        if err then
          error("fs.open write failed: " .. err)
        end
        
        -- Write data
        local written, err = fs.write(fd, content .. "iter=" .. iter .. "\n")
        if err then
          error("fs.write failed: " .. err)
        end
        
        -- Close file
        err = fs.close(fd)
        if err then
          error("fs.close failed: " .. err)
        end
        
        -- Stat file
        local stat, err = fs.stat(filename)
        if err then
          error("fs.stat failed: " .. err)
        end
        assert(stat.size > 0, "stat.size should be > 0")
        
        -- Open for reading
        fd, err = fs.open(filename, "r")
        if err then
          error("fs.open read failed: " .. err)
        end
        
        -- Read data
        local data, err = fs.read(fd, 1024)
        if err then
          error("fs.read failed: " .. err)
        end
        assert(#data > 0, "read data should not be empty")
        
        -- Close file
        err = fs.close(fd)
        if err then
          error("fs.close failed: " .. err)
        end
      end
      
      completed.fs_ops = completed.fs_ops + 1
      log(string.format("FS worker %d completed (%d iterations)", i, ITERATIONS))
    end)
  end
  
  -- Test scandir
  lunet.spawn(function()
    lunet.sleep(100)  -- Wait for files to be created
    
    local entries, err = fs.scandir(TEST_DIR)
    if err then
      error("fs.scandir failed: " .. err)
    end
    
    log(string.format("Scandir found %d entries", #entries))
    for _, entry in ipairs(entries) do
      log(string.format("  %s (%s)", entry.name, entry.type))
    end
    
    completed.fs_ops = completed.fs_ops + 1
  end)
end

--------------------------------------------------------------------------------
-- Socket Tests
--------------------------------------------------------------------------------
local function test_sockets()
  log("Starting socket tests...")
  
  -- Start server
  lunet.spawn(function()
    local server, err = socket.listen("tcp", "127.0.0.1", TEST_PORT)
    if err then
      error("socket.listen failed: " .. err)
    end
    
    log(string.format("Server listening on port %d", TEST_PORT))
    
    -- Accept CONCURRENCY connections
    for i = 1, CONCURRENCY do
      local client, err = socket.accept(server)
      if err then
        error("socket.accept failed: " .. err)
      end
      
      -- Handle client in separate coroutine
      lunet.spawn(function()
        local peer, err = socket.getpeername(client)
        log(string.format("Accepted connection %d from %s", i, peer or "unknown"))
        
        -- Echo loop
        for j = 1, ITERATIONS do
          local data, err = socket.read(client)
          if err then
            log(string.format("Client %d read error: %s", i, err))
            break
          end
          if not data then
            log(string.format("Client %d disconnected", i))
            break
          end
          
          -- Echo back
          err = socket.write(client, "ECHO:" .. data)
          if err then
            log(string.format("Client %d write error: %s", i, err))
            break
          end
        end
        
        socket.close(client)
        completed.socket_ops = completed.socket_ops + 1
        log(string.format("Server handler %d completed", i))
      end)
    end
    
    -- Keep server open briefly then close
    lunet.sleep(500)
    socket.close(server)
    log("Server closed")
  end)
  
  -- Start clients after a brief delay
  lunet.sleep(50)
  
  for i = 1, CONCURRENCY do
    lunet.spawn(function()
      local conn, err = socket.connect("127.0.0.1", TEST_PORT)
      if err then
        error(string.format("Client %d connect failed: %s", i, err))
      end
      
      log(string.format("Client %d connected", i))
      
      for j = 1, ITERATIONS do
        local msg = string.format("Hello from client %d, message %d", i, j)
        
        err = socket.write(conn, msg)
        if err then
          error(string.format("Client %d write failed: %s", i, err))
        end
        
        local response, err = socket.read(conn)
        if err then
          error(string.format("Client %d read failed: %s", i, err))
        end
        
        assert_eq(response, "ECHO:" .. msg, "Echo mismatch")
      end
      
      socket.close(conn)
      completed.clients = completed.clients + 1
      log(string.format("Client %d completed", i))
    end)
  end
end

--------------------------------------------------------------------------------
-- Main Test Runner
--------------------------------------------------------------------------------
log("===========================================")
log("  LUNET TRACE TEST")
log("===========================================")
log(string.format("Configuration: PORT=%d, CONCURRENCY=%d, ITERATIONS=%d", 
                  TEST_PORT, CONCURRENCY, ITERATIONS))
log("")

-- Run all tests
test_timers()
test_fs()
test_sockets()

-- Completion checker
lunet.spawn(function()
  local max_wait = 10000  -- 10 seconds
  local waited = 0
  local check_interval = 100
  
  while waited < max_wait do
    lunet.sleep(check_interval)
    waited = waited + check_interval
    
    -- Check if all tests completed
    local all_done = 
      completed.timers >= CONCURRENCY and
      completed.fs_ops >= CONCURRENCY + 1 and  -- +1 for scandir
      completed.socket_ops >= CONCURRENCY and
      completed.clients >= CONCURRENCY
    
    if all_done then
      break
    end
  end
  
  log("")
  log("===========================================")
  log("  TEST RESULTS")
  log("===========================================")
  log(string.format("Timers:     %d/%d", completed.timers, CONCURRENCY))
  log(string.format("FS ops:     %d/%d", completed.fs_ops, CONCURRENCY + 1))
  log(string.format("Socket ops: %d/%d", completed.socket_ops, CONCURRENCY))
  log(string.format("Clients:    %d/%d", completed.clients, CONCURRENCY))
  
  local success = 
    completed.timers >= CONCURRENCY and
    completed.fs_ops >= CONCURRENCY + 1 and
    completed.socket_ops >= CONCURRENCY and
    completed.clients >= CONCURRENCY
  
  if success then
    log("")
    log("ALL TESTS PASSED!")
    log("")
    log("If LUNET_TRACE is enabled, check trace summary above for:")
    log("  - coref_balance = 0")
    log("  - All coroutine references properly balanced")
  else
    log("")
    log("SOME TESTS FAILED!")
    os.exit(1)
  end
  
  -- Cleanup
  os.execute("rm -rf " .. TEST_DIR)
end)

log("Tests started, waiting for completion...")
