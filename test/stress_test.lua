--[[
  Stress Test for Lunet Coroutine Safety

  This test spawns many concurrent coroutines that perform async operations
  to stress-test the coroutine reference tracking and stack integrity checks.

  Run with LUNET_TRACE=ON build to catch:
  - Stack pollution bugs
  - Coroutine reference leaks
  - Double-release bugs
  - Race conditions in reference counting

  Usage:
    ./build/lunet test/stress_test.lua [num_workers] [ops_per_worker]

  Default: 50 workers, 100 ops each = 5000 total operations
]]

local lunet = require('lunet')
local fs = require('lunet.fs')

-- Configuration (from environment or defaults)
local NUM_WORKERS = tonumber(os.getenv("STRESS_WORKERS")) or 50
local OPS_PER_WORKER = tonumber(os.getenv("STRESS_OPS")) or 100
local TIMEOUT_MS = tonumber(os.getenv("STRESS_TIMEOUT_MS")) or 30000

-- Counters (simple, non-atomic - just for rough stats)
local completed_workers = 0
local completed_ops = 0
local errors = 0
local start_time = os.clock()

-- Test operations that exercise coroutine yields
local function test_sleep(_id)
    lunet.sleep(1)  -- Minimal sleep to yield
    return true
end

local function test_fs_stat(_id)
    local stat = fs.stat(".")
    if not stat then
        errors = errors + 1
        return false
    end
    return true
end

local function test_fs_scandir(_id)
    local entries = fs.scandir(".")
    if not entries then
        errors = errors + 1
        return false
    end
    return true
end

-- Mix of operations to stress different code paths
local operations = {
    test_sleep,
    test_fs_stat,
    test_fs_scandir,
}

-- Worker function - performs many async operations
local function worker(worker_id)
    for i = 1, OPS_PER_WORKER do
        -- Pick random operation
        local op_idx = (worker_id + i) % #operations + 1
        local op = operations[op_idx]

        local ok, err = pcall(op, worker_id)
        if ok then
            completed_ops = completed_ops + 1
        else
            errors = errors + 1
            io.stderr:write(string.format("[STRESS] Worker %d op %d error: %s\n",
                worker_id, i, tostring(err)))
        end

        -- Occasional progress report
        if completed_ops % 500 == 0 then
            io.stderr:write(string.format("[STRESS] Progress: %d ops completed\n", completed_ops))
        end
    end

    completed_workers = completed_workers + 1
end

-- Watchdog - kills test if it hangs
local function watchdog()
    local waited = 0
    while waited < TIMEOUT_MS and not _G.__lunet_exit_code do
        lunet.sleep(100)
        waited = waited + 100
    end
    if _G.__lunet_exit_code then
        return
    end
    io.stderr:write(string.format("\n[STRESS] TIMEOUT after %dms!\n", TIMEOUT_MS))
    io.stderr:write(string.format("[STRESS] Completed: %d/%d workers, %d ops, %d errors\n",
        completed_workers, NUM_WORKERS, completed_ops, errors))
    -- Hard-exit on timeout to avoid wedging CI; this will skip trace shutdown.
    os.exit(1)
end

-- Main
io.stderr:write(string.format("[STRESS] Starting stress test: %d workers x %d ops = %d total\n",
    NUM_WORKERS, OPS_PER_WORKER, NUM_WORKERS * OPS_PER_WORKER))

-- Start watchdog
lunet.spawn(watchdog)

-- Spawn all workers concurrently
for i = 1, NUM_WORKERS do
    lunet.spawn(function()
        worker(i)
    end)
end

-- Wait for completion (poll-based since we can't join coroutines)
lunet.spawn(function()
    while completed_workers < NUM_WORKERS do
        lunet.sleep(100)
    end

    local elapsed = os.clock() - start_time

    print(string.format("\n[STRESS] COMPLETED"))
    print(string.format("[STRESS] Workers: %d/%d", completed_workers, NUM_WORKERS))
    print(string.format("[STRESS] Operations: %d", completed_ops))
    print(string.format("[STRESS] Errors: %d", errors))
    print(string.format("[STRESS] Time: %.3fs", elapsed))
    print(string.format("[STRESS] Ops/sec: %.0f", completed_ops / elapsed))

    if errors > 0 then
        print("[STRESS] FAILED - errors detected")
        _G.__lunet_exit_code = 1
    else
        print("[STRESS] PASSED")
        _G.__lunet_exit_code = 0
    end
end)
