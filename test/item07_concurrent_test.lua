-- Test for Item 07: Concurrent SET Verification (Lua; replaces the .sh version).
-- Usage: lunet-run test/item07_concurrent_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local test_client = root .. "/test/item07_test_client.lua"
local cfg = root .. "/.tmp/advisory_lock_config.lua"
local ready_hi = root .. "/.tmp/advisory_lock_node_n1_ready"
local ready_lo = root .. "/.tmp/advisory_lock_node_n2_ready"
local hi_log = root .. "/.tmp/test_item07_hi.log"
local lo_log = root .. "/.tmp/test_item07_lo.log"
local client_log = root .. "/.tmp/test_item07_client.log"

local t = H.new_tally()
local hi_pid, lo_pid

local function cleanup()
    if lo_pid then H.kill(lo_pid, "KILL") end
    if hi_pid then H.kill(hi_pid, "KILL") end
    os.remove(ready_hi)
    os.remove(ready_lo)
end

lunet.spawn(function()
    for _, p in ipairs({ ready_hi, ready_lo, cfg, hi_log, lo_log, client_log }) do os.remove(p) end

    t.check(H.run_config_gen(bin, cfg), "config file created")

    hi_pid = H.spawn_proc(bin .. " " .. node .. " " .. H.quote(cfg) .. " n1", hi_log)
    t.check(H.wait_file(ready_hi, 5000), "HI ready within 5s")

    lo_pid = H.spawn_proc(bin .. " " .. node .. " " .. H.quote(cfg) .. " n2", lo_log)
    t.check(H.wait_file(ready_lo, 5000), "LO ready within 5s")

    local client_ok = H.run_ok(bin .. " " .. test_client .. " > "
        .. H.quote(client_log) .. " 2>&1")
    local client_out = H.readfile(client_log) or ""
    io.stdout:write(client_out)
    if not client_ok then
        io.stderr:write("--- HI node log ---\n" .. (H.readfile(hi_log) or ""))
        io.stderr:write("--- LO node log ---\n" .. (H.readfile(lo_log) or ""))
    end
    t.check(client_ok, "item07 test client exited 0")

    t.check(H.kill_and_wait(hi_pid, 3000), "HI terminated")
    t.check(H.kill_and_wait(lo_pid, 3000), "LO terminated")

    cleanup()
    t.exit()
end)
