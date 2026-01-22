local native = require("lunet.db")
local config = require("app.db_config")

local db = {}

-- Expose native functions
db.open = native.open
db.close = native.close
db.query_raw = native.query
db.exec_raw = native.exec

function db.set_config(cfg)
    if not cfg then return end
    for k, v in pairs(cfg) do
        config[k] = v
    end
end

-- Connection management
function db.connect()
    -- Native open takes a table. db_config matches what's needed.
    return native.open(config)
end

-- Escape function
function db.escape(value)
    if value == nil then
        return "NULL"
    elseif type(value) == "number" then
        return tostring(value)
    elseif type(value) == "boolean" then
        return value and "1" or "0"
    else
        -- Native escape handles the character escaping (e.g. ' -> '' or \ -> \\)
        -- We must wrap in quotes.
        return "'" .. native.escape(tostring(value)) .. "'"
    end
end

-- Interpolate: replace ? with escaped values
function db.interpolate(sql, ...)
    local args = {...}
    local idx = 0
    return sql:gsub("%?", function()
        idx = idx + 1
        return db.escape(args[idx])
    end)
end

-- Higher level query (handles connection and interpolation)
function db.query(sql, ...)
    local conn, err = db.connect()
    if not conn then
        return nil, err
    end

    local function run(s, ...)
        if select("#", ...) > 0 then
            s = db.interpolate(s, ...)
        end
        return db.query_raw(conn, s)
    end

    local ok, result, query_err = pcall(run, sql, ...)
    db.close(conn)
    
    if not ok then
        return nil, result
    end

    if not result then
        return nil, query_err or "query failed"
    end

    return result
end

function db.exec(sql, ...)
    local conn, err = db.connect()
    if not conn then
        return nil, err
    end

    local function run(s, ...)
        if select("#", ...) > 0 then
            s = db.interpolate(s, ...)
        end
        return db.exec_raw(conn, s)
    end

    local ok, result, exec_err = pcall(run, sql, ...)
    db.close(conn)
    
    if not ok then
        return nil, result
    end

    if not result then
        return nil, exec_err or "exec failed"
    end

    return result
end

function db.query_one(sql, ...)
    local result, err = db.query(sql, ...)
    if not result then return nil, err end
    if #result == 0 then return nil end
    return result[1]
end

-- Table helpers
function db.insert(table_name, data)
    local columns = {}
    local values = {}
    for col, val in pairs(data) do
        columns[#columns + 1] = col
        values[#values + 1] = db.escape(val)
    end
    local sql = string.format(
        "INSERT INTO %s (%s) VALUES (%s)",
        table_name, -- Note: table name not escaped, assumed safe/constant
        table.concat(columns, ", "),
        table.concat(values, ", ")
    )
    return db.exec(sql)
end

function db.update(table_name, data, where, ...)
    local sets = {}
    for col, val in pairs(data) do
        sets[#sets + 1] = col .. " = " .. db.escape(val)
    end
    local sql = string.format(
        "UPDATE %s SET %s WHERE %s",
        table_name,
        table.concat(sets, ", "),
        db.interpolate(where, ...)
    )
    return db.exec(sql)
end

function db.delete(table_name, where, ...)
    local sql = string.format(
        "DELETE FROM %s WHERE %s",
        table_name,
        db.interpolate(where, ...)
    )
    return db.exec(sql)
end

function db.init()
    if config.driver == "sqlite" or config.driver == "sqlite3" then
        local conn, err = db.connect()
        if not conn then return nil, err end
        
        -- Read schema
        local f = io.open("app/schema_sqlite.sql", "rb")
        if not f then 
            -- Fallback to main schema if sqlite specific one missing?
            f = io.open("app/schema.sql", "rb") 
        end
        
        if f then
            local schema = f:read("*a")
            f:close()
            db.exec_raw(conn, schema)
        end
        db.close(conn)
    end
    return true
end

return db