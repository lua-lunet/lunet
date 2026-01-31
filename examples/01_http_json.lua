local lunet = require("lunet")
local socket = require("lunet.socket")

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

local listener = nil

local function parse_request_line(data)
    local first_line = data:match("^([^\r\n]+)")
    if not first_line then return nil end
    local method, path = first_line:match("^(%w+)%s+([^%s]+)")
    if not method then return nil end
    return method, path
end

local function handle_request(client)
    local data, err = socket.read(client)
    if not data then
        socket.close(client)
        return
    end

    local method, path = parse_request_line(data)

    local response_body = json_encode({
        message = "Hello from Lunet!",
        request = {
            method = method,
            path = path,
        },
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
    local lerr
    listener, lerr = socket.listen("tcp", "127.0.0.1", 18080)
    if not listener then
        print("Failed to listen: " .. (lerr or "unknown"))
        return
    end

    print("HTTP+JSON example server listening on http://127.0.0.1:18080")
    print("Try:")
    print("  curl http://127.0.0.1:18080/")
    print("  curl http://127.0.0.1:18080/hello")

    while true do
        local client, cerr = socket.accept(listener)
        if client then
            lunet.spawn(function()
                handle_request(client)
            end)
        end
    end
end)
