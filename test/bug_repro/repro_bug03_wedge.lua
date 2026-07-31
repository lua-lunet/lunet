-- repro_bug03 + repro_bug05: lost peer reply wedges node; logs discarded.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local C = dofile(script_dir .. "/common.lua")
local lunet = require("lunet")
local udp = require("lunet.udp")

local root = C.repo_root()
local bin = C.lunet_bin(root)
local cfg = root .. "/.tmp/bug_repro_config.lua"
local ev_dir = root .. "/.tmp/bug_repro"
os.execute("mkdir -p " .. C.quote(ev_dir))

local hi_pid, lo_pid
local function cleanup()
    if lo_pid then C.kill(lo_pid, "CONT") end
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
    assert(os.execute(bin .. " " .. root
        .. "/examples/advisory_lock_cas/config_gen.lua --output " .. cfg) == 0)
    local config = dofile(cfg)
    local lock_mod = dofile(root .. "/examples/advisory_lock_cas/lock.lua")

    hi_pid = C.spawn_bg(bin .. " " .. root .. "/examples/advisory_lock_cas/node.lua "
        .. cfg .. " n1", ev_dir .. "/node_hi35.log")
    assert(wait_file(root .. "/.tmp/advisory_lock_node_n1_ready", 5000), "hi not ready")
    lo_pid = C.spawn_bg(bin .. " " .. root .. "/examples/advisory_lock_cas/node.lua "
        .. cfg .. " n2", ev_dir .. "/node_lo35.log")
    assert(wait_file(root .. "/.tmp/advisory_lock_node_n2_ready", 5000), "lo not ready")

    -- BUG-5 probe: do one normal SET via hi so a handler line should exist.
    do
        local h = assert(udp.bind("127.0.0.1", 0))
        local t0 = string.format("%016x", lock_mod.pack_token(5, 0))
        udp.send(h, "127.0.0.1", config.n1.client_port, "SET /locks/5 " .. t0 .. " 9 e5000001")
        udp.recv(h)
        udp.close(h)
    end
    -- Give stdio a chance; do NOT terminate the node (that is the point of BUG-5).
    lunet.sleep(200)
    local hi_log_live = C.readfile(ev_dir .. "/node_hi35.log") or ""

    -- BUG-3 probe: SIGSTOP lo, then SET to hi. Client waits with its own deadline.
    C.kill(lo_pid, "STOP")
    lunet.sleep(100)
    local h2 = assert(udp.bind("127.0.0.1", 0))
    local t1 = string.format("%016x", lock_mod.pack_token(5, 9))
    udp.send(h2, "127.0.0.1", config.n1.client_port, "SET /locks/5 " .. t1 .. " 7 e5000002")
    local wedged = true
    local deadline = 0
    lunet.spawn(function()
        local data = udp.recv(h2)
        if data then wedged = false end
    end)
    while deadline < 3000 do
        if not wedged then break end
        lunet.sleep(50)
        deadline = deadline + 50
    end
    C.kill(lo_pid, "CONT")

    local f = assert(io.open(ev_dir .. "/bug03_05.log", "w"))
    f:write("BUG-5: node log while running (should contain handler lines, does not):\n")
    f:write("---- live node_hi35.log begin ----\n", hi_log_live, "\n---- end ----\n")
    f:write("BUG-3: SET to hi with lo SIGSTOPped: client reply within 3s? ",
        wedged and "NO (wedged)" or "yes", "\n")
    f:close()
    print("evidence: " .. ev_dir .. "/bug03_05.log")
    cleanup()
    os.exit(0)
end)
