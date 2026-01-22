local lunet = require("lunet")
local socket = require("lunet.socket")
local db = require("lunet.db")

local escape_chars = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escape_string(s)
    return s:gsub('[\\"\b\f\n\r\t]', escape_chars):gsub("[%z\1-\31]", function(c)
        return string.format("\\u%04x", string.byte(c))
    end)
end

local function is_array(t)
    if type(t) ~= "table" then return false end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

local encode_value

local function encode_table(t)
    if is_array(t) then
        local parts = {}
        for i, v in ipairs(t) do
            parts[i] = encode_value(v)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    else
        local parts = {}
        for k, v in pairs(t) do
            if type(k) == "string" then
                parts[#parts + 1] = '"' .. escape_string(k) .. '":' .. encode_value(v)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
end

function encode_value(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v then return "null" end
        if v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    elseif t == "string" then
        return '"' .. escape_string(v) .. '"'
    elseif t == "table" then
        return encode_table(v)
    else
        return "null"
    end
end

local function json_encode(value)
    return encode_value(value)
end

local function sql_escape(value)
    if value == nil then return "NULL" end
    if type(value) == "number" then return tostring(value) end
    return "'" .. db.escape(tostring(value)) .. "'"
end

local listener = nil
local conn = nil

local function handle_request(client)
    local data, err = socket.read(client)
    if not data then
        socket.close(client)
        return
    end

    local users = {}
    if conn then
        local rows, qerr = db.query(conn, "SELECT id, name, email FROM users LIMIT 10")
        if rows then
            users = rows
        end
    end

    local response_body = json_encode({
        message = "Hello from Lunet!",
        users = users,
        example = {
            string = "Hello, World!",
            number = 42,
            boolean = true,
            array = {1, 2, 3},
            nested = { key = "value" }
        }
    })

    local response = "HTTP/1.1 200 OK\r\n" ..
        "Content-Type: application/json\r\n" ..
        "Content-Length: " .. #response_body .. "\r\n\r\n" ..
        response_body

    socket.write(client, response)
    socket.close(client)
end

lunet.spawn(function()
    conn = db.open({ path = ":memory:" })
    if conn then
        local _, cerr = db.exec(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
        if cerr then print("CREATE TABLE error: " .. cerr) end
        
        local _, ierr1 = db.exec(conn, string.format(
            "INSERT INTO users (name, email) VALUES (%s, %s)",
            sql_escape("Alice"),
            sql_escape("alice@example.com")
        ))
        if ierr1 then print("INSERT error: " .. ierr1) end
        
        local _, ierr2 = db.exec(conn, string.format(
            "INSERT INTO users (name, email) VALUES (%s, %s)",
            sql_escape("O'Brien"),
            sql_escape("obrien@example.com")
        ))
        if ierr2 then print("INSERT error: " .. ierr2) end
        
        print("Database initialized with sample data")
    end

    local lerr
    listener, lerr = socket.listen("tcp", "127.0.0.1", 8080)
    if not listener then
        print("Failed to listen: " .. (lerr or "unknown"))
        return
    end

    print("JSON API server listening on http://127.0.0.1:8080")
    print("Try: curl http://127.0.0.1:8080/")

    while true do
        local client, cerr = socket.accept(listener)
        if client then
            lunet.spawn(function()
                handle_request(client)
            end)
        end
    end
end)
