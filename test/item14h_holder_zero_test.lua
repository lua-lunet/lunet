-- RED PHASE (item14): SET with holder=0 must be rejected with INVALID.
-- Fails until item15 (codec INVALID) + item16 (node validation).
-- holder=0 is the unheld sentinel; it must never be assigned by a SET.
-- Usage (after rework): lunet-run test/item14h_holder_zero_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local codec = dofile(root .. "/examples/advisory_lock_cas/codec.lua")
local lockm = dofile(root .. "/examples/advisory_lock_cas/lock.lua")

local cfg = root .. "/.tmp/item14h_config.lua"
local ready_n1 = root .. "/.tmp/advisory_lock_node_n1_ready"
local ready_n2 = root .. "/.tmp/advisory_lock_node_n2_ready"

local t = H.new_tally()
local pids = {}

local function cleanup()
    for _, p in pairs(pids) do H.kill(p, "KILL") end
    os.remove(ready_n1)
    os.remove(ready_n2)
    os.remove(cfg)
end

lunet.spawn(function()
    for _, p in ipairs({ ready_n1, ready_n2, cfg }) do os.remove(p) end
    assert(H.run_config_gen(bin, cfg), "config_gen failed")
    local config = dofile(cfg)

    for _, label in ipairs({ "n1", "n2" }) do
        local log = root .. "/.tmp/item14h_" .. label .. ".log"
        local ready = (label == "n1") and ready_n1 or ready_n2
        pids[label] = H.spawn_proc(bin .. " " .. node .. " "
            .. H.quote(cfg) .. " " .. label, log)
        assert(H.wait_file(ready, 5000), label .. " not ready")
    end

    local port = config.n1.client_port

    -- Seed lock 7 with holder=11.
    local t0 = string.format("%016x", lockm.pack_token(7, 0))
    local data = H.udp_request(port, "SET /locks/7 " .. t0 .. " 11 aa000001", 3000)
    local m = data and codec.parse(data)
    assert(m and m.status == "OK", "seed SET failed")

    -- SET holder=0 must be INVALID and must not change the lock.
    local t1 = string.format("%016x", lockm.pack_token(7, 11))
    data = H.udp_request(port, "SET /locks/7 " .. t1 .. " 0 aa000002", 3000)
    m = data and codec.parse(data)
    t.check(m ~= nil and m.status == "INVALID",
        "SET holder=0 rejected with INVALID (got " .. (m and m.status or "no reply") .. ")")

    data = H.udp_request(port, "GET /locks/7 aa000003", 2000)
    m = data and codec.parse(data)
    t.check(m ~= nil and m.holder == 11,
        "lock unchanged after holder=0 attempt (holder=" .. tostring(m and m.holder) .. ")")

    -- GET on an unheld lock still reports the sentinel.
    data = H.udp_request(port, "GET /locks/8 aa000004", 2000)
    m = data and codec.parse(data)
    t.check(m ~= nil and m.status == "OK" and m.holder == 0,
        "GET on unheld lock returns holder=0 sentinel")

    cleanup()
    t.exit()
end)
