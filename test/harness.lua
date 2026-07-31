-- Shared Lua test harness for the advisory_lock_cas demo and its drivers.
-- Replaces all shell-script orchestration. Process spawning uses
-- io.popen(cmd .. " & echo $!"); logic stays in Lua.
--
-- Coroutine rule: wait_file, kill_and_wait, bind_check and sleep_ms call
-- lunet.sleep and MUST be used inside lunet.spawn. Pure helpers work
-- anywhere.

local M = {}

local _root = nil
function M.repo_root()
    if _root then return _root end
    local p = io.popen("git rev-parse --show-toplevel 2>/dev/null")
    local out = p and p:read("*l") or nil
    if p then p:close() end
    _root = out or "."
    return _root
end

function M.quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.find_lunet_bin()
    local env = os.getenv("LUNET_BIN")
    if env and env ~= "" then
        local f = io.open(env, "r")
        if f then f:close() return env end
    end
    local p = io.popen('find "' .. M.repo_root()
        .. '/build" -path "*/release/lunet-run" -type f 2>/dev/null | head -1')
    local out = p:read("*l")
    p:close()
    if not out or out == "" then error("lunet-run binary not found") end
    return out
end

function M.readfile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

function M.writefile(path, data)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(data)
    f:close()
    return true
end

function M.file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- Spawn a background process, stdout/stderr to log_path. Returns pid.
function M.spawn_proc(cmd, log_path)
    local p = io.popen(cmd .. ' > ' .. M.quote(log_path) .. ' 2>&1 & echo $!')
    local pid = tonumber(p:read("*l"))
    p:close()
    if not pid then error("failed to spawn: " .. cmd) end
    return pid
end

-- Run a command to completion. Returns true on exit status 0.
function M.run_ok(cmd)
    return os.execute(cmd) == 0
end

function M.kill(pid, sig)
    os.execute("kill -" .. (sig or "TERM") .. " " .. tonumber(pid) .. " 2>/dev/null")
end

function M.alive(pid)
    return os.execute("kill -0 " .. tonumber(pid) .. " 2>/dev/null") == 0
end

-- Coroutine-only: poll for a file up to timeout_ms. Returns true if found.
function M.wait_file(path, timeout_ms)
    local lunet = require("lunet")
    local waited = 0
    while waited < timeout_ms do
        if M.file_exists(path) then return true end
        lunet.sleep(50)
        waited = waited + 50
    end
    return M.file_exists(path)
end

-- Coroutine-only: TERM then wait for the process to disappear.
function M.kill_and_wait(pid, timeout_ms)
    local lunet = require("lunet")
    M.kill(pid, "TERM")
    local waited = 0
    timeout_ms = timeout_ms or 3000
    while waited < timeout_ms do
        if not M.alive(pid) then return true end
        lunet.sleep(50)
        waited = waited + 50
    end
    M.kill(pid, "KILL")
    return not M.alive(pid)
end

-- Coroutine-only: check a UDP port is free by binding it.
function M.port_free(port)
    local udp = require("lunet.udp")
    local h = udp.bind("127.0.0.1", port)
    if h then
        udp.close(h)
        return true
    end
    return false
end

-- Coroutine-only: send wire to 127.0.0.1:port on a throwaway socket and
-- await a reply up to timeout_ms. Returns the data string or nil on
-- timeout. Uses a nested coroutine for the deadline; udp.close releases it.
function M.udp_request(port, wire, timeout_ms)
    local lunet = require("lunet")
    local udp = require("lunet.udp")
    local h = assert(udp.bind("127.0.0.1", 0))
    local result = nil
    lunet.spawn(function()
        local data = udp.recv(h)
        result = data or false
    end)
    udp.send(h, "127.0.0.1", port, wire)
    local waited = 0
    while result == nil and waited < timeout_ms do
        lunet.sleep(5)
        waited = waited + 5
    end
    udp.close(h)
    return result or nil
end

function M.run_config_gen(bin, out_path)
    local gen = M.repo_root() .. "/examples/advisory_lock_cas/config_gen.lua"
    os.remove(out_path)
    local ok = M.run_ok(bin .. " " .. gen .. " --output " .. M.quote(out_path))
    return ok and M.file_exists(out_path)
end

-- Numeric (ip, port) comparison: returns -1/0/1 for a vs b.
function M.addr_cmp(ip_a, port_a, ip_b, port_b)
    local function ip_num(ip)
        local n = 0
        for oct in tostring(ip):gmatch("%d+") do
            n = n * 256 + tonumber(oct)
        end
        return n
    end
    local a, b = ip_num(ip_a), ip_num(ip_b)
    if a ~= b then return a < b and -1 or 1 end
    if port_a == port_b then return 0 end
    return port_a < port_b and -1 or 1
end

-- Which config label ("n1"/"n2") is the HIGH node per (ip, port) ordering.
function M.high_label(config)
    local a, b = config.n1, config.n2
    local host_a, host_b = a.host or "127.0.0.1", b.host or "127.0.0.1"
    if M.addr_cmp(host_a, a.client_port, host_b, b.client_port) > 0 then
        return "n1"
    end
    return "n2"
end

-- Tally helpers (same pattern as existing test clients).
function M.new_tally()
    local t = { failures = 0, checks = 0 }
    function t.check(cond, msg)
        t.checks = t.checks + 1
        if not cond then
            t.failures = t.failures + 1
            io.stderr:write("FAIL: " .. msg .. "\n")
        else
            print("   OK: " .. msg)
        end
    end
    function t.exit()
        print(t.failures > 0
            and ("=== " .. t.failures .. "/" .. t.checks .. " FAILURES ===")
            or ("=== all " .. t.checks .. " checks passed ==="))
        os.exit(t.failures > 0 and 1 or 0)
    end
    return t
end

return M
