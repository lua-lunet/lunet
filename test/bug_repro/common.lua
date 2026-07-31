-- Shared helpers for bug repro scripts. Evidence capture, not assertions.
local M = {}

function M.repo_root()
    local p = io.popen("git rev-parse --show-toplevel 2>/dev/null")
    local out = p:read("*l")
    p:close()
    return out or "."
end

function M.lunet_bin(root)
    local p = io.popen('find "' .. root .. '/build" -path "*/release/lunet-run" -type f 2>/dev/null | head -1')
    local out = p:read("*l")
    p:close()
    if not out or out == "" then error("lunet-run not found") end
    return out
end

function M.spawn_bg(cmd, log_path)
    local p = io.popen(cmd .. ' > "' .. log_path .. '" 2>&1 & echo $!')
    local pid = tonumber(p:read("*l"))
    p:close()
    return pid
end

function M.kill(pid, sig)
    os.execute("kill -" .. (sig or "TERM") .. " " .. pid .. " 2>/dev/null")
end

function M.quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.readfile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

return M
