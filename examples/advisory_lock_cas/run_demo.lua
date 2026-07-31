-- E2E driver for the advisory_lock_cas demo (Lua; replaces run_demo.sh).
-- Usage: lunet-run examples/advisory_lock_cas/run_demo.lua
-- Env: LUNET_BIN overrides the release binary search.

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/../../test/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local test_client = root .. "/test/item05_test_client.lua"
local cfg = root .. "/.tmp/advisory_lock_config.lua"
local ready_hi = root .. "/.tmp/advisory_lock_node_n1_ready"
local ready_lo = root .. "/.tmp/advisory_lock_node_n2_ready"

local stamp = os.date("%Y%m%d_%H%M%S")
local logdir = root .. "/.tmp/logs/" .. stamp
local hi_log = logdir .. "/node_hi.log"
local lo_log = logdir .. "/node_lo.log"

local hi_pid, lo_pid
local function cleanup()
    if lo_pid then H.kill(lo_pid, "KILL") end
    if hi_pid then H.kill(hi_pid, "KILL") end
end

local function fail(msg)
    io.stderr:write("FAIL: " .. msg .. "\n")
    if H.file_exists(hi_log) then
        io.stderr:write("--- HI node log ---\n" .. (H.readfile(hi_log) or "") .. "\n")
    end
    if H.file_exists(lo_log) then
        io.stderr:write("--- LO node log ---\n" .. (H.readfile(lo_log) or "") .. "\n")
    end
    cleanup()
    os.exit(1)
end

lunet.spawn(function()
    assert(H.run_ok("mkdir -p " .. H.quote(logdir)), "mkdir logdir failed")
    for _, p in ipairs({ ready_hi, ready_lo, cfg }) do os.remove(p) end

    print("--- Generating config ---")
    if not H.run_config_gen(bin, cfg) then fail("config file not created") end

    print("--- Starting HI node ---")
    hi_pid = H.spawn_proc(bin .. " " .. node .. " " .. H.quote(cfg) .. " n1", hi_log)
    if not H.wait_file(ready_hi, 5000) then
        fail(H.alive(hi_pid) and "Hi not ready in 5s" or "HI node exited prematurely")
    end

    print("--- Starting LO node ---")
    lo_pid = H.spawn_proc(bin .. " " .. node .. " " .. H.quote(cfg) .. " n2", lo_log)
    if not H.wait_file(ready_lo, 5000) then
        fail(H.alive(lo_pid) and "Lo not ready in 5s" or "LO node exited prematurely")
    end

    print("--- Running test client ---")
    local client_ok = H.run_ok(bin .. " " .. test_client)
    if not client_ok then fail("test client exited non-zero") end

    H.kill_and_wait(hi_pid, 3000)
    H.kill_and_wait(lo_pid, 3000)
    hi_pid, lo_pid = nil, nil

    print("PASS: E2E test passed (logs in .tmp/logs/" .. stamp .. "/)")
    cleanup()
    os.exit(0)
end)
