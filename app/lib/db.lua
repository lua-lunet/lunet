local mysql = require("lunet.mysql")

local db = {}

local config = {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "root",
    database = "conduit",
}

local connection = nil

function db.set_config(cfg)
    if cfg.host then config.host = cfg.host end
    if cfg.port then config.port = cfg.port end
    if cfg.user then config.user = cfg.user end
    if cfg.password then config.password = cfg.password end
    if cfg.database then config.database = cfg.database end
end

function db.connect()
    if connection then
        return connection
    end
    local conn, err = mysql.open({
        host = config.host,
        port = config.port,
        user = config.user,
        password = config.password,
        database = config.database,
        charset = "utf8mb4",
    })
    if not conn then
        return nil, "database connection failed: " .. (err or "unknown error")
    end
    connection = conn
    return conn
end

function db.close()
    if connection then
        mysql.close(connection)
        connection = nil
    end
end

function db.escape(value)
    if value == nil then
        return "NULL"
    elseif type(value) == "number" then
        return tostring(value)
    elseif type(value) == "boolean" then
        return value and "1" or "0"
    elseif type(value) == "string" then
        local escaped = value:gsub("\\", "\\\\")
        escaped = escaped:gsub("'", "\\'")
        escaped = escaped:gsub('"', '\\"')
        escaped = escaped:gsub("\n", "\\n")
        escaped = escaped:gsub("\r", "\\r")
        escaped = escaped:gsub("%z", "\\0")
        escaped = escaped:gsub("\x1a", "\\Z")
        return "'" .. escaped .. "'"
    else
        return "NULL"
    end
end

function db.interpolate(sql, ...)
    local args = {...}
    local idx = 0
    return sql:gsub("%?", function()
        idx = idx + 1
        return db.escape(args[idx])
    end)
end

function db.query(sql, ...)
    local conn, err = db.connect()
    if not conn then
        return nil, err
    end

    if select("#", ...) > 0 then
        sql = db.interpolate(sql, ...)
    end

    local result, query_err = mysql.query(conn, sql)
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

    if select("#", ...) > 0 then
        sql = db.interpolate(sql, ...)
    end

    local result, exec_err = mysql.exec(conn, sql)
    if not result then
        return nil, exec_err or "exec failed"
    end

    return result
end

function db.query_one(sql, ...)
    local result, err = db.query(sql, ...)
    if not result then
        return nil, err
    end
    if #result == 0 then
        return nil
    end
    return result[1]
end

function db.insert(table_name, data)
    local columns = {}
    local values = {}
    for col, val in pairs(data) do
        columns[#columns + 1] = col
        values[#values + 1] = db.escape(val)
    end
    local sql = string.format(
        "INSERT INTO %s (%s) VALUES (%s)",
        table_name,
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

return db
