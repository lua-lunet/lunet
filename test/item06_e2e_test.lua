-- Test for Item 06: E2E Harness (Lua; replaces the .sh version).
-- Usage: lunet-run test/item06_e2e_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local t = H.new_tally()

local function newest_logdir()
    local p = io.popen('ls -1dt "' .. root .. '/.tmp/logs"/*/ 2>/dev/null | head -1')
    local out = p:read("*l")
    p:close()
    return out
end

lunet.spawn(function()
    local demo = root .. "/examples/advisory_lock_cas/run_demo.lua"
    t.check(H.run_ok("cd " .. H.quote(root) .. " && " .. bin .. " " .. demo),
        "run_demo.lua exits 0")

    local logdir = newest_logdir()
    t.check(logdir ~= nil and logdir ~= "", "log directory created")
    local hi = logdir and H.readfile(logdir .. "node_hi.log") or nil
    local lo = logdir and H.readfile(logdir .. "node_lo.log") or nil
    t.check(hi ~= nil and hi:find("^READY label=n1 ") ~= nil, "node_hi.log has READY line")
    t.check(lo ~= nil and lo:find("^READY label=n2 ") ~= nil, "node_lo.log has READY line")

    local cfg = root .. "/.tmp/advisory_lock_config.lua"
    local config = H.file_exists(cfg) and dofile(cfg) or nil
    if config then
        lunet.sleep(300)
        t.check(H.port_free(config.n1.client_port), "HI client port freed after run")
        t.check(H.port_free(config.n2.client_port), "LO client port freed after run")
    else
        t.check(false, "config file missing after run")
    end

    t.exit()
end)
