-- Shared strictness gate and env-driven connection config for the database
-- smoke tests (test/smoke_mysql.lua, test/smoke_postgres.lua). Loaded via
-- dofile() from a sibling path so the scripts work from any working directory.
--
-- LUNET_DB_REQUIRED: when truthy, a failed db.open is a hard failure
-- (exit 1, with a message naming the host, port and database attempted);
-- when unset the historical SKIP-and-exit-0 behaviour is retained verbatim
-- so developer machines without a database keep passing. The xmake smoke
-- task honours the same variable for its "driver module not built" branch.

local M = {}

local REQUIRED_VAR = "LUNET_DB_REQUIRED"

local function truthy(value)
    if type(value) ~= "string" then
        return false
    end
    local v = value:lower()
    return v ~= "" and v ~= "0" and v ~= "false" and v ~= "no" and v ~= "off"
end

function M.required()
    return truthy(os.getenv(REQUIRED_VAR))
end

-- Resolve connection parameters from the environment, falling back to the
-- script's historical literals. prefix selects the variable names: with
-- prefix "MYSQL" this reads LUNET_MYSQL_HOST, LUNET_MYSQL_PORT,
-- LUNET_MYSQL_USER, LUNET_MYSQL_PASSWORD and LUNET_MYSQL_DATABASE.
function M.config(prefix, defaults)
    local function env(name)
        local v = os.getenv("LUNET_" .. prefix .. "_" .. name)
        if v == nil or v == "" then
            return nil
        end
        return v
    end
    return {
        host = env("HOST") or defaults.host,
        port = tonumber(env("PORT")) or defaults.port,
        user = env("USER") or defaults.user,
        password = env("PASSWORD") or defaults.password,
        database = env("DATABASE") or defaults.database
    }
end

-- Handle a failed db.open(). Lenient mode prints the historical SKIP lines
-- verbatim and exits 0; required mode prints a hard failure naming the
-- host, port and database attempted and exits 1.
function M.open_failed(label, cfg, err)
    if M.required() then
        print("FAIL: Could not connect to " .. label .. ": " .. tostring(err))
        print("   (" .. REQUIRED_VAR .. " is set - a reachable database is mandatory)")
        print("   attempted host=" .. tostring(cfg.host)
            .. " port=" .. tostring(cfg.port)
            .. " database=" .. tostring(cfg.database))
        __lunet_exit_code = 1
    else
        print("SKIP: Could not connect to " .. label .. ": " .. tostring(err))
        print("   (" .. label .. " may not be running - this is OK for CI)")
        __lunet_exit_code = 0
    end
end

return M
