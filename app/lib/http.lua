local json = require("app.lib.json")

local format = string.format
local ipairs  = ipairs
local pairs   = pairs

local http = {}

local STATUS_TEXTS = {
    [200] = "OK",
    [201] = "Created",
    [204] = "No Content",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [422] = "Unprocessable Entity",
    [500] = "Internal Server Error",
}

function http.parse_query_string(query)
    local params = {}
    if not query or query == "" then
        return params
    end
    for pair in query:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]+)=(.*)$")
        if key then
            key = key:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            value = value:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            value = value:gsub("+", " ")
            params[key] = value
        end
    end
    return params
end

function http.parse_request(data)
    local request = {
        method = nil,
        path = nil,
        query_string = nil,
        query_params = {},
        headers = {},
        body = nil,
        params = {},
    }

    local header_end = data:find("\r\n\r\n")
    if not header_end then
        return nil, "incomplete request"
    end

    local header_section = data:sub(1, header_end - 1)
    local body = data:sub(header_end + 4)

    local lines = {}
    for line in header_section:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end

    if #lines < 1 then
        return nil, "no request line"
    end

    local request_line = lines[1]
    local method, path_with_query = request_line:match("^(%S+)%s+(%S+)%s+%S+$")
    if not method then
        return nil, "invalid request line"
    end

    request.method = method:upper()

    local path, query_string = path_with_query:match("^([^?]+)%?(.*)$")
    if path then
        request.path = path
        request.query_string = query_string
        request.query_params = http.parse_query_string(query_string)
    else
        request.path = path_with_query
    end

    for i = 2, #lines do
        local name, value = lines[i]:match("^([^:]+):%s*(.*)$")
        if name then
            request.headers[name:lower()] = value
        end
    end

    local content_length = request.headers["content-length"]
    if content_length then
        content_length = tonumber(content_length)
        if content_length and content_length > 0 then
            request.body = body:sub(1, content_length)
        end
    end

    return request
end

function http.response(status, headers, body)
    local status_text = STATUS_TEXTS[status] or "Unknown"
    local parts = {"HTTP/1.1 " .. status .. " " .. status_text .. "\r\n"}

    headers = headers or {}
    if body and not headers["Content-Length"] then
        headers["Content-Length"] = #body
    end

    for name, value in pairs(headers) do
        parts[#parts + 1] = name .. ": " .. tostring(value) .. "\r\n"
    end

    parts[#parts + 1] = "\r\n"

    if body then
        parts[#parts + 1] = body
    end

    return table.concat(parts)
end

function http.json_response(status, data)
    local body = json.encode(data)
    return http.response(status, {
        ["Content-Type"] = "application/json; charset=utf-8",
        ["Connection"] = "close",
    }, body)
end

local function normalize_errors(errors)
    local messages = {}
    local function add(msg)
        if msg and msg ~= "" then
            messages[#messages + 1] = tostring(msg)
        end
    end

    if errors == nil then
        add("Unknown error")
    elseif type(errors) == "string" then
        add(errors)
    elseif type(errors) == "table" then
        if #errors > 0 then
            for _, msg in ipairs(errors) do
                add(msg)
            end
        else
            for key, val in pairs(errors) do
                if type(val) == "table" then
                    for _, msg in ipairs(val) do
                        add(format("%s %s", key, msg))
                    end
                else
                    add(val)
                end
            end
        end
    end

    if #messages == 0 then
        messages[1] = "Unknown error"
    end
    return messages
end

function http.error_response(status, errors)
    local body_errors = normalize_errors(errors)
    return http.json_response(status, {errors = {body = body_errors}})
end

function http.cors_headers()
    return {
        ["Access-Control-Allow-Origin"] = "*",
        ["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS",
        ["Access-Control-Allow-Headers"] = "Content-Type, Authorization",
        ["Access-Control-Max-Age"] = "86400",
    }
end

function http.options_response()
    local headers = http.cors_headers()
    headers["Content-Length"] = "0"
    return http.response(204, headers, "")
end

return http
