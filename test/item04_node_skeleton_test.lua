-- Test for Item 04: Node Process Skeleton (Lua; replaces the .sh version).
-- Usage: lunet-run test/item04_node_skeleton_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local cfg = root .. "/.tmp/test_item04_config.lua"
local ready_hi = root .. "/.tmp/advisory_lock_node_n1_ready"
local ready_lo = root .. "/.tmp/advisory_lock_node_n2_ready"
local hi_log = root .. "/.tmp/test_item04_hi.log"
local lo_log = root .. "/.tmp/test_item04_lo.log"

local t = H.new_tally()
local hi_pid, lo_pid

local function cleanup()
    if lo_pid then H.kill(lo_pid, "KILL") end
    if hi_pid then H.kill(hi_pid, "KILL") end
    os.remove(ready_hi)
    os.remove(ready_lo)
    os.remove(cfg)
end

local function log_has_error(path)
    local data = H.readfile(path) or ""
    for line in data:gmatch("[^\n]+") do
        local l = line:lower()
        if l:find("error", 1, true) and not l:find("terminated", 1, true) then
            return true, line
        end
        if line:find("^FAIL") then
            return true, line
        end
    end
    return false
end

lunet.spawn(function()
    for _, p in ipairs({ ready_hi, ready_lo, cfg, hi_log, lo_log }) do os.remove(p) end

    t.check(H.run_config_gen(bin, cfg), "config file created")

    hi_pid = H.spawn_proc(bin .. " " .. node .. " " .. H.quote(cfg) .. " n1", hi_log)
    t.check(H.wait_file(ready_hi, 5000), "HI readiness file within 5s")
    t.check(H.alive(hi_pid), "HI node alive after ready")

    local hi_data = H.readfile(hi_log) or ""
    t.check(hi_data:find("^READY label=n1 ") ~= nil, "READY label=n1 line in HI log")
    t.check(hi_data:find("order=HIGH") ~= nil or hi_data:find("order=LOW") ~= nil,
        "derived order logged in HI READY line")

    lo_pid = H.spawn_proc(bin .. " " .. node .. " " .. H.quote(cfg) .. " n2", lo_log)
    t.check(H.wait_file(ready_lo, 5000), "LO readiness file within 5s")
    t.check(H.alive(lo_pid), "LO node alive after ready")

    local lo_data = H.readfile(lo_log) or ""
    t.check(lo_data:find("^READY label=n2 ") ~= nil, "READY label=n2 line in LO log")

    t.check(H.kill_and_wait(hi_pid, 3000), "HI node terminated after SIGTERM")
    t.check(H.kill_and_wait(lo_pid, 3000), "LO node terminated after SIGTERM")

    local herr, hline = log_has_error(hi_log)
    t.check(not herr, "no Error/FAIL in HI log" .. (herr and (" (" .. tostring(hline) .. ")") or ""))
    local lerr, lline = log_has_error(lo_log)
    t.check(not lerr, "no Error/FAIL in LO log" .. (lerr and (" (" .. tostring(lline) .. ")") or ""))

    local config = dofile(cfg)
    lunet.sleep(300)
    t.check(H.port_free(config.n1.client_port), "HI client port freed")
    t.check(H.port_free(config.n2.client_port), "LO client port freed")
    t.check(H.port_free(config.n1.peer_listen_port), "HI peer_listen port freed")
    t.check(H.port_free(config.n2.peer_listen_port), "LO peer_listen port freed")

    cleanup()
    t.exit()
end)
