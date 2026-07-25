-- Minimal JSON encode/decode for the OpenAlex MCP example.
-- Pure Lua 5.1 / LuaJIT, no dependencies. Covers the full JSON data model;
-- decode is strict enough for API payloads (objects, arrays, strings with
-- \uXXXX escapes, numbers, literals). Not a general-purpose validator.

local M = {}

-- ---------------------------------------------------------------- encoder

local escape_map = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escape_string(s)
    return s:gsub('[\\"\b\f\n\r\t]', escape_map):gsub("[%z\1-\31]", function(c)
        return string.format("\\u%04x", string.byte(c))
    end)
end

-- A table with only contiguous integer keys 1..n (n > 0) encodes as an
-- array; everything else, including the empty table, encodes as an object
-- (API payloads mean {} far more often than [] when a table is empty).
local function is_array(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for _ in pairs(t) do
        n = n + 1
        if t[n] == nil then return false end
    end
    return n > 0
end

local encode_value

local function encode_table(t)
    if is_array(t) then
        local parts = {}
        for i, v in ipairs(t) do
            parts[i] = encode_value(v)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, v in pairs(t) do
        if type(k) == "string" then
            parts[#parts + 1] = '"' .. escape_string(k) .. '":' .. encode_value(v)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    elseif t == "string" then
        return '"' .. escape_string(v) .. '"'
    elseif t == "table" then
        return encode_table(v)
    end
    return "null"
end

function M.encode(v)
    return encode_value(v)
end

-- ---------------------------------------------------------------- decoder

local function utf8_encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    return string.char(
        0xE0 + math.floor(cp / 0x1000),
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40)
end

local string_escapes = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local parse_value  -- forward declaration

local function parse_error(str, pos, msg)
    error(string.format("JSON parse error at byte %d: %s", pos, msg), 0)
end

local function skip_ws(str, pos)
    local _, e = str:find("^[ \t\r\n]*", pos)
    return (e or pos - 1) + 1
end

local function parse_string(str, pos)
    -- str[pos] == '"'
    local parts = {}
    local i = pos + 1
    local start = i
    local len = #str
    while true do
        if i > len then parse_error(str, pos, "unterminated string") end
        local c = str:sub(i, i)
        if c == '"' then
            parts[#parts + 1] = str:sub(start, i - 1)
            return table.concat(parts), i + 1
        elseif c == "\\" then
            parts[#parts + 1] = str:sub(start, i - 1)
            local esc = str:sub(i + 1, i + 1)
            if esc == "u" then
                local hex = str:sub(i + 2, i + 5)
                local cp = tonumber(hex, 16)
                if not cp or #hex < 4 then parse_error(str, i, "bad \\u escape") end
                parts[#parts + 1] = utf8_encode(cp)
                i = i + 6
            else
                local rep = string_escapes[esc]
                if not rep then parse_error(str, i, "bad escape \\" .. esc) end
                parts[#parts + 1] = rep
                i = i + 2
            end
            start = i
        else
            i = i + 1
        end
    end
end

local function parse_number(str, pos)
    local s, e = str:find("^%-?%d+%.?%d*[eE]?[+%-]?%d*", pos)
    if not s then parse_error(str, pos, "invalid number") end
    local text = str:sub(s, e)
    local n = tonumber(text)
    if not n then parse_error(str, pos, "invalid number '" .. text .. "'") end
    return n, e + 1
end

local function parse_array(str, pos)
    local arr = {}
    local i = skip_ws(str, pos + 1)
    if str:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local v
        v, i = parse_value(str, i)
        arr[#arr + 1] = v
        i = skip_ws(str, i)
        local c = str:sub(i, i)
        if c == "," then
            i = skip_ws(str, i + 1)
        elseif c == "]" then
            return arr, i + 1
        else
            parse_error(str, i, "expected ',' or ']' in array")
        end
    end
end

local function parse_object(str, pos)
    local obj = {}
    local i = skip_ws(str, pos + 1)
    if str:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        if str:sub(i, i) ~= '"' then parse_error(str, i, "expected string key") end
        local key
        key, i = parse_string(str, i)
        i = skip_ws(str, i)
        if str:sub(i, i) ~= ":" then parse_error(str, i, "expected ':'") end
        i = skip_ws(str, i + 1)
        local v
        v, i = parse_value(str, i)
        obj[key] = v
        i = skip_ws(str, i)
        local c = str:sub(i, i)
        if c == "," then
            i = skip_ws(str, i + 1)
        elseif c == "}" then
            return obj, i + 1
        else
            parse_error(str, i, "expected ',' or '}' in object")
        end
    end
end

parse_value = function(str, pos)
    local i = skip_ws(str, pos)
    local c = str:sub(i, i)
    if c == "{" then
        return parse_object(str, i)
    elseif c == "[" then
        return parse_array(str, i)
    elseif c == '"' then
        return parse_string(str, i)
    elseif c == "t" then
        if str:sub(i, i + 3) == "true" then return true, i + 4 end
        parse_error(str, i, "invalid literal")
    elseif c == "f" then
        if str:sub(i, i + 4) == "false" then return false, i + 5 end
        parse_error(str, i, "invalid literal")
    elseif c == "n" then
        if str:sub(i, i + 3) == "null" then return nil, i + 4 end
        parse_error(str, i, "invalid literal")
    end
    return parse_number(str, i)
end

-- Decodes the first JSON value in `str`. Returns value, or nil + error.
-- JSON null decodes to Lua nil (so object keys with null simply vanish).
function M.decode(str)
    if type(str) ~= "string" then return nil, "expected string input" end
    local ok, value = pcall(parse_value, str, 1)
    if not ok then return nil, value end
    return value
end

return M
