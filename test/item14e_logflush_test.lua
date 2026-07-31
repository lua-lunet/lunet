-- RED PHASE (item14): node logs must be line-buffered. Fails until
-- item16 (io.stdout:setvbuf("line")). BUG-5: handler lines must reach the
-- log file while the node is STILL RUNNING.
-- Usage (after rework): lunet-run test/item14e_logflush_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local codec = dofile(root .. "/examples/advisory_lock_cas/codec.lua")
local lockm = dofile(root .. "/examples/advisory_lock_cas/lock.lua")

local cfg = root .. "/.tmp/item14e_config.lua"
local ready_n1 = root .. "/.tmp/advisory_lock_node_n1_ready"
local ready_n2 = root .. "/.tmp/advisory_lock_node_n2_ready"
local log_n1 = root .. "/.tmp/item14e_n1.log"

local t = H.new_tally()
local pids = {}

local function cleanup()
    for _, p in pairs(pids) do H.kill(p, "KILL") end
    os.remove(ready_n1)
    os.remove(ready_n2)
    os.remove(cfg)
end

lunet.spawn(function()
    for _, p in ipairs({ ready_n1, ready_n2, cfg, log_n1 }) do os.remove(p) end
    assert(H.run_config_gen(bin, cfg), "config_gen failed")
    local config = dofile(cfg)
    local high = H.high_label(config)

    for _, label in ipairs({ "n1", "n2" }) do
        local log = root .. "/.tmp/item14e_" .. label .. ".log"
        local ready = (label == "n1") and ready_n1 or ready_n2
        pids[label] = H.spawn_proc(bin .. " " .. node .. " "
            .. H.quote(cfg) .. " " .. label, log)
        assert(H.wait_file(ready, 5000), label .. " not ready")
    end

    local t0 = string.format("%016x", lockm.pack_token(6, 0))
    for i = 1, 3 do
        local data = H.udp_request(config[high].client_port,
            "SET /locks/6 " .. t0 .. " " .. (30 + i) .. " " .. string.format("ee%06x", i), 3000)
        local m = data and codec.parse(data)
        if m and m.status == "OK" then
            t0 = string.format("%016x", m.token)
        end
    end

    -- Nodes still running: handler lines must already be in the log.
    lunet.sleep(200)
    local live_log = H.readfile(root .. "/.tmp/item14e_" .. high .. ".log") or ""
    t.check(live_log:find("client_handler SET") ~= nil,
        "handler lines visible in node log while node is running")

    cleanup()
    t.exit()
end)
