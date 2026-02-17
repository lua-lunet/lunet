-- Test utilities for concurrent testing
local lunet = require("lunet")

local M = {}

-- Run multiple coroutines concurrently and wait for completion
function M.run_concurrent(tasks, options)
  options = options or {}
  local timeout = options.timeout or 5.0  -- seconds
  local results = {}
  local errors = {}
  local completed = 0
  local total = #tasks
  local start_time = lunet.time()

  -- Launch all tasks
  for i, task in ipairs(tasks) do
    lunet.spawn(function()
      local ok, result, err = pcall(task.fn, task)
      if ok then
        results[i] = result
        if err then
          errors[i] = err
        end
      else
        errors[i] = "Task failed: " .. tostring(result)
      end
      completed = completed + 1
    end)
  end

  -- Wait for completion or timeout
  while completed < total do
    lunet.sleep(0.01)
    if lunet.time() - start_time > timeout then
      error("Concurrent tasks timed out after " .. timeout .. " seconds")
    end
  end

  return {
    results = results,
    errors = errors,
    completed = completed,
    total = total
  }
end

-- Simulate race conditions with controlled delays
function M.race_condition_simulator(options)
  options = options or {}
  local delay_min = options.delay_min or 0.001
  local delay_max = options.delay_max or 0.01
  local iterations = options.iterations or 100
  local shared_state = options.shared_state or {}
  local violations = {}

  local function random_delay()
    lunet.sleep(delay_min + math.random() * (delay_max - delay_min))
  end

  return {
    delay = random_delay,
    iterations = iterations,
    shared_state = shared_state,
    violations = violations,
    add_violation = function(msg)
      table.insert(violations, msg)
    end,
    get_violations = function()
      return violations
    end
  }
end

-- Test concurrent access to shared resource
function M.test_concurrent_access(options)
  options = options or {}
  local thread_count = options.thread_count or 10
  local operations_per_thread = options.operations_per_thread or 100
  local shared_resource = options.shared_resource or {}
  local access_log = {}
  local violations = {}

  local tasks = {}
  for i = 1, thread_count do
    table.insert(tasks, {
      id = i,
      fn = function(task)
        for j = 1, operations_per_thread do
          -- Log access
          table.insert(access_log, {
            thread_id = task.id,
            operation = j,
            timestamp = lunet.time()
          })

          -- Perform operation on shared resource
          if options.operation then
            local ok, err = pcall(options.operation, shared_resource, task.id, j)
            if not ok then
              table.insert(violations, "Thread " .. task.id .. " operation " .. j .. " failed: " .. err)
            end
          end

          -- Small delay to increase chance of race conditions
          lunet.sleep(0.0001)
        end
        return { thread_id = task.id, operations = operations_per_thread }
      end
    })
  end

  local result = M.run_concurrent(tasks, options)

  return {
    access_log = access_log,
    violations = violations,
    concurrent_result = result,
    thread_count = thread_count,
    operations_per_thread = operations_per_thread
  }
end

-- Deadlock detection utility
function M.detect_deadlock(options)
  options = options or {}
  local timeout = options.timeout or 10.0  -- seconds
  local start_time = lunet.time()
  local lock_states = {}

  return {
    acquire_lock = function(lock_id, thread_id)
      lock_states[lock_id] = lock_states[lock_id] or {}
      if lock_states[lock_id].holder then
        -- Check for deadlock (circular wait)
        if lunet.time() - start_time > timeout then
          error("Potential deadlock detected on lock " .. lock_id ..
                " held by thread " .. lock_states[lock_id].holder)
        end
        return false  -- Lock not available
      end
      lock_states[lock_id].holder = thread_id
      lock_states[lock_id].acquired_at = lunet.time()
      return true
    end,

    release_lock = function(lock_id, thread_id)
      if lock_states[lock_id] and lock_states[lock_id].holder == thread_id then
        lock_states[lock_id].holder = nil
        lock_states[lock_id].released_at = lunet.time()
        return true
      end
      return false
    end,

    get_lock_state = function(lock_id)
      return lock_states[lock_id]
    end
  }
end

-- Resource leak detector
function M.detect_resource_leak(_options)
  local resources = {}
  local allocations = {}
  local deallocations = {}

  return {
    allocate = function(resource_id, resource_type, metadata)
      resources[resource_id] = {
        type = resource_type,
        allocated_at = lunet.time(),
        metadata = metadata or {}
      }
      allocations[resource_type] = (allocations[resource_type] or 0) + 1
    end,

    deallocate = function(resource_id, resource_type)
      if resources[resource_id] then
        resources[resource_id] = nil
        deallocations[resource_type] = (deallocations[resource_type] or 0) + 1
        return true
      end
      return false
    end,

    get_leaks = function()
      local leaks = {}
      for id, resource in pairs(resources) do
        table.insert(leaks, {
          id = id,
          type = resource.type,
          allocated_at = resource.allocated_at,
          metadata = resource.metadata
        })
      end
      return leaks
    end,

    get_stats = function()
      local stats = {}
      for resource_type, count in pairs(allocations) do
        local deallocated = deallocations[resource_type] or 0
        stats[resource_type] = {
          allocated = count,
          deallocated = deallocated,
          leaked = count - deallocated
        }
      end
      return stats
    end
  }
end

-- Performance benchmark for concurrent operations
function M.benchmark_concurrent(options)
  options = options or {}
  local iterations = options.iterations or 1000
  local thread_counts = options.thread_counts or {1, 2, 4, 8}
  local results = {}

  for _, thread_count in ipairs(thread_counts) do
    local start_time = lunet.time()

    local tasks = {}
    for _ = 1, thread_count do
      table.insert(tasks, {
        fn = function()
          for _ = 1, iterations // thread_count do
            if options.operation then
              options.operation()
            end
          end
          return { iterations = iterations // thread_count }
        end
      })
    end

    local result = M.run_concurrent(tasks, { timeout = options.timeout or 30 })
    local end_time = lunet.time()

    table.insert(results, {
      thread_count = thread_count,
      total_time = end_time - start_time,
      iterations_per_second = iterations / (end_time - start_time),
      errors = #result.errors
    })
  end

  return results
end

return M
