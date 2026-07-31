-- RED PHASE (item14): peer-loss timeout + guarded rollback. Fails until
-- item16. BUG-3: a wedged peer must not wedge the node; the failed write
-- must be rolled back.
-- Usage (after rework): lunet-run test/item14c_timeout_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local codec = dofile(root .. "/examples/advisory_lock_cas/codec.lua")
local lockm = dofile(root .. "/examples/advisory_lock_cas/lock.lua")

local cfg = root .. "/.tmp/item14c_config.lua"
local ready_n1 = root .. "/.tmp/advisory_lock_node_n1_ready"
local ready_n2 = root .. "/.tmp/advisory_lock_node_n2_ready"

local t = H.new_tally()
local pids = {}

local function cleanup()
    for _, p in pairs(pids) do H.kill(p, "CONT") end
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
        local log = root .. "/.tmp/item14c_" .. label .. ".log"
        local ready = (label == "n1") and ready_n1 or ready_n2
        pids[label] = H.spawn_proc(bin .. " " .. node .. " "
            .. H.quote(cfg) .. " " .. label, log)
        assert(H.wait_file(ready, 5000), label .. " not ready")
    end

    local high = H.high_label(config)
    local low = (high == "n1") and "n2" or "n1"

    -- Baseline: write lock=5 holder=9 via HIGH so both nodes hold state.
    local t0 = string.format("%016x", lockm.pack_token(5, 0))
    local data = H.udp_request(config[high].client_port,
        "SET /locks/5 " .. t0 .. " 9 aa000001", 3000)
    local m = data and codec.parse(data)
    assert(m and m.status == "OK", "baseline SET failed")

    -- SIGSTOP LOW, then SET via HIGH: must get UNAVAILABLE, not a wedge.
    H.kill(pids[low], "STOP")
    lunet.sleep(100)
    local t1 = string.format("%016x", lockm.pack_token(5, 9))
    local started = os.clock()
    data = H.udp_request(config[high].client_port,
        "SET /locks/5 " .. t1 .. " 7 aa000002", 6000)
    local elapsed_ms = (os.clock() - started) * 1000
    m = data and codec.parse(data)
    t.check(m ~= nil and m.status == "UNAVAILABLE",
        "HIGH replies UNAVAILABLE when LOW is down (got "
        .. (m and m.status or "no reply") .. ")")
    t.check(elapsed_ms < 5000, "reply within timeout bound (took "
        .. math.floor(elapsed_ms) .. "ms)")

    -- HIGH still serves GETs (not wedged).
    local h_alive = get_holder(config[high].client_port, 5, "aa000003")
    t.check(h_alive ~= nil, "HIGH still answers GET after peer-loss timeout")

    -- Guarded rollback: failed write did not stick.
    t.check(h_alive == 9, "HIGH rolled back failed write (holder="
        .. tostring(h_alive) .. ", want 9)")

    -- Heal: SIGCONT LOW, retry, both converge on the new holder.
    H.kill(pids[low], "CONT")
    lunet.sleep(300)
    data = H.udp_request(config[high].client_port,
        "SET /locks/5 " .. t1 .. " 7 aa000004", 3000)
    m = data and codec.parse(data)
    t.check(m ~= nil and m.status == "OK", "SET succeeds after heal")
    lunet.sleep(200)
    local h_low = get_holder(config[low].client_port, 5, "aa000005")
    t.check(h_low == 7, "LOW converged to holder=7 after heal (got "
        .. tostring(h_low) .. ")")

    cleanup()
    t.exit()
end)
