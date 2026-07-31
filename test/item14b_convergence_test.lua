-- RED PHASE (item14): convergence after a contested SET. Fails until
-- item16. BUG-1: nodes must agree (no permanent split-brain, no
-- peer-value adoption trading).
-- Usage (after rework): lunet-run test/item14b_convergence_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")
local udp = require("lunet.udp")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local codec = dofile(root .. "/examples/advisory_lock_cas/codec.lua")
local lockm = dofile(root .. "/examples/advisory_lock_cas/lock.lua")

local cfg = root .. "/.tmp/item14b_config.lua"
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

local function get_holder(port, lock_id, msg_id)
    local data = H.udp_request(port, "GET /locks/" .. lock_id .. " " .. msg_id, 2000)
    local m = data and codec.parse(data)
    return m and m.holder or nil
end

lunet.spawn(function()
    for _, p in ipairs({ ready_n1, ready_n2, cfg }) do os.remove(p) end
    assert(H.run_config_gen(bin, cfg), "config_gen failed")
    local config = dofile(cfg)

    for _, label in ipairs({ "n1", "n2" }) do
        local log = root .. "/.tmp/item14b_" .. label .. ".log"
        local ready = (label == "n1") and ready_n1 or ready_n2
        pids[label] = H.spawn_proc(bin .. " " .. node .. " "
            .. H.quote(cfg) .. " " .. label, log)
        assert(H.wait_file(ready, 5000), label .. " not ready")
    end

    -- Contested SET via both nodes simultaneously (barrier).
    local token0 = lockm.pack_token(4, 0)
    local ready_count, release, done = 0, false, 0
    local function writer(port, holder, msg_id)
        lunet.spawn(function()
            local h = assert(udp.bind("127.0.0.1", 0))
            ready_count = ready_count + 1
            while not release do lunet.sleep(0) end
            udp.send(h, "127.0.0.1", port, "SET /locks/4 "
                .. string.format("%016x", token0) .. " " .. holder .. " " .. msg_id)
            udp.recv(h)
            udp.close(h)
            done = done + 1
        end)
    end
    writer(config.n1.client_port, 111, "aa000001")
    writer(config.n2.client_port, 222, "bb000001")
    while ready_count < 2 do lunet.sleep(0) end
    release = true
    local waited = 0
    while done < 2 and waited < 5000 do lunet.sleep(10) waited = waited + 10 end

    -- Poll both nodes until they agree (deadline 2s).
    local agreed = false
    local polls = 0
    while polls < 20 and not agreed do
        local h1 = get_holder(config.n1.client_port, 4, "cc000001")
        local h2 = get_holder(config.n2.client_port, 4, "dd000001")
        if h1 ~= nil and h1 == h2 then agreed = true end
        if not agreed then
            lunet.sleep(100)
            polls = polls + 1
        end
    end
    t.check(agreed, "nodes converge on one holder within 2s of a contested SET")

    cleanup()
    t.exit()
end)
