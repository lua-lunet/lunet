-- repro_bug01: simultaneous CAS -> zero winners + permanent split-brain.
-- Evidence capture for BUG-0/BUG-1. Exits 0 always; writes evidence log.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local C = dofile(script_dir .. "/common.lua")
local lunet = require("lunet")
local udp = require("lunet.udp")

local root = C.repo_root()
local bin = C.lunet_bin(root)
local cfg = root .. "/.tmp/bug_repro_config.lua"
local ev_dir = root .. "/.tmp/bug_repro"
os.execute("mkdir -p " .. C.quote(ev_dir))
os.remove(cfg)

local hi_pid, lo_pid
local function cleanup()
    if hi_pid then C.kill(hi_pid, "KILL") end
    if lo_pid then C.kill(lo_pid, "KILL") end
    os.remove(root .. "/.tmp/advisory_lock_node_n1_ready")
    os.remove(root .. "/.tmp/advisory_lock_node_n2_ready")
end

local function wait_file(path, deadline_ms)
    local waited = 0
    while waited < deadline_ms do
        local f = io.open(path, "r")
        if f then f:close() return true end
        lunet.sleep(50)
        waited = waited + 50
    end
    return false
end

lunet.spawn(function()
    local gen = bin .. " " .. root .. "/examples/advisory_lock_cas/config_gen.lua --output " .. cfg
    assert(os.execute(gen) == 0, "config_gen failed")
    local config = dofile(cfg)

    hi_pid = C.spawn_bg(bin .. " " .. root .. "/examples/advisory_lock_cas/node.lua "
        .. cfg .. " n1", ev_dir .. "/node_hi.log")
    assert(wait_file(root .. "/.tmp/advisory_lock_node_n1_ready", 5000), "hi not ready")
    lo_pid = C.spawn_bg(bin .. " " .. root .. "/examples/advisory_lock_cas/node.lua "
        .. cfg .. " n2", ev_dir .. "/node_lo.log")
    assert(wait_file(root .. "/.tmp/advisory_lock_node_n2_ready", 5000), "lo not ready")

    local lock_mod = dofile(root .. "/examples/advisory_lock_cas/lock.lua")
    local codec = dofile(root .. "/examples/advisory_lock_cas/codec.lua")
    local token0 = lock_mod.pack_token(2, 0)

    -- Two writers, barrier-released together (NO sleep between them).
    local results = {}
    local ready_count, release = 0, false
    local done = 0
    local msg_ids = { a = "aa000001", b = "bb000001" }
    local function writer(tag, target_port, holder)
        lunet.spawn(function()
            local h = assert(udp.bind("127.0.0.1", 0))
            ready_count = ready_count + 1
            while not release do lunet.sleep(0) end
            udp.send(h, "127.0.0.1", target_port,
                "SET /locks/2 " .. string.format("%016x", token0)
                .. " " .. holder .. " " .. msg_ids[tag])
            local data = udp.recv(h)
            results[tag] = data and codec.parse(data) or nil
            udp.close(h)
            done = done + 1
        end)
    end
    writer("a", config.n1.client_port, 100)
    writer("b", config.n2.client_port, 200)
    while ready_count < 2 do lunet.sleep(0) end
    release = true
    local waited = 0
    while done < 2 and waited < 5000 do lunet.sleep(10) waited = waited + 10 end

    -- Read both nodes' view of lock 2.
    local views = {}
    local get_ids = { hi = "cc000001", lo = "dd000001" }
    for tag, port in pairs({ hi = config.n1.client_port, lo = config.n2.client_port }) do
        local h = assert(udp.bind("127.0.0.1", 0))
        udp.send(h, "127.0.0.1", port, "GET /locks/2 " .. get_ids[tag])
        local data = udp.recv(h)
        local m = data and codec.parse(data)
        views[tag] = m and m.holder or "noreply"
        udp.close(h)
    end

    local f = assert(io.open(ev_dir .. "/bug01.log", "w"))
    f:write("BUG-1 repro: simultaneous SET lock=2 (100->hi, 200->lo), no sleep\n")
    f:write("a.status=", results.a and results.a.status or "nil",
        " b.status=", results.b and results.b.status or "nil", "\n")
    f:write("hi_view=", tostring(views.hi), " lo_view=", tostring(views.lo), "\n")
    if results.a and results.b and results.a.status == "CONFLICT" and results.b.status == "CONFLICT" then
        f:write("OBSERVED: zero winners (both CONFLICT)\n")
    end
    if views.hi ~= views.lo then
        f:write("OBSERVED: split-brain (hi=", tostring(views.hi),
            " lo=", tostring(views.lo), ")\n")
    end
    f:close()
    print("evidence: " .. ev_dir .. "/bug01.log")
    cleanup()
    os.exit(0)
end)
