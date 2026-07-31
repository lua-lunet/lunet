-- RED PHASE (item14): S2 write ordering + real concurrency. Fails until
-- item16 (node rework) + item17 (n1/n2 rename) + item18 (barrier fold).
-- BUG-0/BUG-1/BUG-2: barrier-released simultaneous SETs must produce
-- exactly one winner, and the LOW node must never self-commit.
-- Usage (after rework): lunet-run test/item14a_s2_ordering_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")
local udp = require("lunet.udp")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local codec = dofile(root .. "/examples/advisory_lock_cas/codec.lua")
local lockm = dofile(root .. "/examples/advisory_lock_cas/lock.lua")

local cfg = root .. "/.tmp/item14a_config.lua"
local ready_n1 = root .. "/.tmp/advisory_lock_node_n1_ready"
local ready_n2 = root .. "/.tmp/advisory_lock_node_n2_ready"
local log_n1 = root .. "/.tmp/item14a_n1.log"
local log_n2 = root .. "/.tmp/item14a_n2.log"

local t = H.new_tally()
local pids = {}

local function cleanup()
    for _, p in pairs(pids) do H.kill(p, "CONT") end
    for _, p in pairs(pids) do H.kill(p, "KILL") end
    os.remove(ready_n1)
    os.remove(ready_n2)
    os.remove(cfg)
end

local function start(label, log, ready)
    pids[label] = H.spawn_proc(bin .. " " .. node .. " " .. H.quote(cfg) .. " " .. label, log)
    return H.wait_file(ready, 5000)
end

local function get_holder(port, lock_id, msg_id)
    local data = H.udp_request(port, "GET /locks/" .. lock_id .. " " .. msg_id, 2000)
    local m = data and codec.parse(data)
    return m and m.holder or nil, m and m.token or nil
end

lunet.spawn(function()
    for _, p in ipairs({ ready_n1, ready_n2, cfg, log_n1, log_n2 }) do os.remove(p) end
    assert(H.run_config_gen(bin, cfg), "config_gen failed")
    local config = dofile(cfg)
    assert(start("n1", log_n1, ready_n1), "n1 not ready")
    assert(start("n2", log_n2, ready_n2), "n2 not ready")

    -- ── Leg 1: barrier-released simultaneous SETs ──
    local token0 = lockm.pack_token(2, 0)
    local results = {}
    local ready_count, release, done = 0, false, 0
    local function writer(tag, port, holder, msg_id)
        lunet.spawn(function()
            local h = assert(udp.bind("127.0.0.1", 0))
            ready_count = ready_count + 1
            while not release do lunet.sleep(0) end
            udp.send(h, "127.0.0.1", port, "SET /locks/2 "
                .. string.format("%016x", token0) .. " " .. holder .. " " .. msg_id)
            local data = udp.recv(h)
            results[tag] = data and codec.parse(data) or nil
            udp.close(h)
            done = done + 1
        end)
    end
    writer("a", config.n1.client_port, 100, "aa000001")
    writer("b", config.n2.client_port, 200, "bb000001")
    while ready_count < 2 do lunet.sleep(0) end
    release = true
    local waited = 0
    while done < 2 and waited < 5000 do lunet.sleep(10) waited = waited + 10 end
    t.check(done == 2, "both writers received replies (no wedge)")

    local a_ok = results.a and results.a.status == "OK"
    local b_ok = results.b and results.b.status == "OK"
    t.check((a_ok and not b_ok) or (b_ok and not a_ok),
        "exactly one OK and one CONFLICT (a="
        .. (results.a and results.a.status or "nil") .. " b="
        .. (results.b and results.b.status or "nil") .. ")")

    local winner = a_ok and 100 or 200
    local loser_reply = a_ok and results.b or results.a
    t.check(loser_reply ~= nil and loser_reply.status == "CONFLICT"
        and loser_reply.holder == winner,
        "loser CONFLICT carries winner holder=" .. winner)

    local h1 = get_holder(config.n1.client_port, 2, "cc000001")
    local h2 = get_holder(config.n2.client_port, 2, "dd000001")
    t.check(h1 == winner, "n1 agrees on winner holder=" .. winner .. " (got " .. tostring(h1) .. ")")
    t.check(h2 == winner, "n2 agrees on winner holder=" .. winner .. " (got " .. tostring(h2) .. ")")

    -- ── Leg 2: LOW never self-commits (S2) ──
    local high = H.high_label(config)
    local low = (high == "n1") and "n2" or "n1"
    H.kill(pids[high], "STOP")
    lunet.sleep(100)

    local t3 = string.format("%016x", lockm.pack_token(3, 0))
    local data = H.udp_request(config[low].client_port,
        "SET /locks/3 " .. t3 .. " 5 ee000001", 4000)
    local m = data and codec.parse(data)
    t.check(m ~= nil and (m.status == "UNAVAILABLE" or m.status == "CONFLICT"),
        "LOW replies UNAVAILABLE/CONFLICT when HIGH is down (got "
        .. (m and m.status or "no reply") .. ")")
    local h3 = get_holder(config[low].client_port, 3, "ee000002")
    t.check(h3 == 0, "LOW did not self-commit lock=3 (holder=" .. tostring(h3) .. ")")
    H.kill(pids[high], "CONT")

    cleanup()
    t.exit()
end)
