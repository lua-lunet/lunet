-- RED PHASE (item14): nc driver. Fails until item19 wires the Makefile
-- target (the test itself works once item16/17 land). Spec: advisory
-- locks fired at the nodes with nc. SKIP (exit 0) if nc is absent.
-- Usage (after rework): lunet-run test/item14j_nc_driver_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local node = root .. "/examples/advisory_lock_cas/node.lua"
local codec = dofile(root .. "/examples/advisory_lock_cas/codec.lua")
local lockm = dofile(root .. "/examples/advisory_lock_cas/lock.lua")

local cfg = root .. "/.tmp/item14j_config.lua"
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

local function have_nc()
    return H.run_ok("command -v nc >/dev/null 2>&1")
end

local function get_holder(port, lock_id, msg_id)
    local data = H.udp_request(port, "GET /locks/" .. lock_id .. " " .. msg_id, 2000)
    local m = data and codec.parse(data)
    return m and m.holder or nil
end

lunet.spawn(function()
    if not have_nc() then
        print("SKIP: nc not available")
        os.exit(0)
    end

    for _, p in ipairs({ ready_n1, ready_n2, cfg }) do os.remove(p) end
    assert(H.run_config_gen(bin, cfg), "config_gen failed")
    local config = dofile(cfg)

    for _, label in ipairs({ "n1", "n2" }) do
        local log = root .. "/.tmp/item14j_" .. label .. ".log"
        local ready = (label == "n1") and ready_n1 or ready_n2
        pids[label] = H.spawn_proc(bin .. " " .. node .. " "
            .. H.quote(cfg) .. " " .. label, log)
        assert(H.wait_file(ready, 5000), label .. " not ready")
    end

    -- Fire a SET at n1 with nc (fire-and-forget; reply is unread by nc).
    local t0 = string.format("%016x", lockm.pack_token(9, 0))
    local wire = "SET /locks/9 " .. t0 .. " 55 ee000001"
    local pipe = io.popen("printf '%s\\n' " .. H.quote(wire)
        .. " | nc -u -w1 127.0.0.1 " .. config.n1.client_port .. " >/dev/null 2>&1; echo done")
    pipe:read("*a")
    pipe:close()

    -- Verify via Lua GET polling (up to 2s) on BOTH nodes.
    local deadline = 0
    local h1, h2
    repeat
        h1 = get_holder(config.n1.client_port, 9, "ee000002")
        h2 = get_holder(config.n2.client_port, 9, "ee000003")
        if h1 == 55 and h2 == 55 then break end
        lunet.sleep(100)
        deadline = deadline + 100
    until deadline >= 2000
    t.check(h1 == 55, "nc-fired SET visible on n1 (holder=" .. tostring(h1) .. ")")
    t.check(h2 == 55, "nc-fired SET visible on n2 (holder=" .. tostring(h2) .. ")")

    cleanup()
    t.exit()
end)
