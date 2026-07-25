-- Tiny .env loader: KEY=VALUE lines, '#' comments, optional quotes.
-- Returns a table; real environment variables still win at lookup time
-- (see get below), so `VAR=x lunet-run ...` overrides the file.

local M = {}

function M.load(path)
    local vars = {}
    local fh = io.open(path or ".env", "r")
    if not fh then return vars end
    for line in fh:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local key, value = trimmed:match("^([%w_]+)%s*=%s*(.-)%s*$")
            if key then
                value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
                vars[key] = value
            end
        end
    end
    fh:close()
    return vars
end

-- Lookup order: process environment first, then the .env table.
function M.get(vars, key)
    return os.getenv(key) or vars[key]
end

return M
