local json = {}

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
        if v ~= v then
            return "null"
        elseif v == math.huge or v == -math.huge then
            return "null"
        else
            return tostring(v)
        end
    elseif t == "string" then
        return '"' .. escape_string(v) .. '"'
    elseif t == "table" then
        return encode_table(v)
    else
        return "null"
    end
end

function json.encode(value)
    return encode_value(value)
end

local decode_value
local decode_scanwhite
local decode_scanstring
local decode_scannumber
local decode_scanarray
local decode_scanobject

local function decode_error(str, idx, msg)
    local line = 1
    local col = 1
    for i = 1, idx do
        if str:sub(i, i) == "\n" then
            line = line + 1
            col = 1
        else
            col = col + 1
        end
    end
    error(string.format("JSON decode error at line %d col %d: %s", line, col, msg))
end

function decode_scanwhite(str, idx)
    while idx <= #str do
        local c = str:sub(idx, idx)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            idx = idx + 1
        else
            break
        end
    end
    return idx
end

local unescape_map = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
}

function decode_scanstring(str, idx)
    local start = idx + 1
    local parts = {}
    local i = start
    while i <= #str do
        local c = str:sub(i, i)
        if c == '"' then
            parts[#parts + 1] = str:sub(start, i - 1)
            return table.concat(parts), i + 1
        elseif c == "\\" then
            parts[#parts + 1] = str:sub(start, i - 1)
            i = i + 1
            local esc = str:sub(i, i)
            if unescape_map[esc] then
                parts[#parts + 1] = unescape_map[esc]
                i = i + 1
            elseif esc == "u" then
                local hex = str:sub(i + 1, i + 4)
                if #hex ~= 4 or not hex:match("^%x%x%x%x$") then
                    decode_error(str, i, "invalid unicode escape")
                end
                local codepoint = tonumber(hex, 16)
                if codepoint < 0x80 then
                    parts[#parts + 1] = string.char(codepoint)
                elseif codepoint < 0x800 then
                    parts[#parts + 1] = string.char(
                        0xC0 + math.floor(codepoint / 64),
                        0x80 + (codepoint % 64)
                    )
                else
                    parts[#parts + 1] = string.char(
                        0xE0 + math.floor(codepoint / 4096),
                        0x80 + math.floor((codepoint % 4096) / 64),
                        0x80 + (codepoint % 64)
                    )
                end
                i = i + 5
            else
                decode_error(str, i, "invalid escape sequence")
            end
            start = i
        else
            i = i + 1
        end
    end
    decode_error(str, idx, "unterminated string")
end

function decode_scannumber(str, idx)
    local start = idx
    if str:sub(idx, idx) == "-" then
        idx = idx + 1
    end
    if str:sub(idx, idx) == "0" then
        idx = idx + 1
    elseif str:sub(idx, idx):match("[1-9]") then
        idx = idx + 1
        while str:sub(idx, idx):match("%d") do
            idx = idx + 1
        end
    else
        decode_error(str, idx, "invalid number")
    end
    if str:sub(idx, idx) == "." then
        idx = idx + 1
        if not str:sub(idx, idx):match("%d") then
            decode_error(str, idx, "invalid number")
        end
        while str:sub(idx, idx):match("%d") do
            idx = idx + 1
        end
    end
    if str:sub(idx, idx):lower() == "e" then
        idx = idx + 1
        if str:sub(idx, idx) == "+" or str:sub(idx, idx) == "-" then
            idx = idx + 1
        end
        if not str:sub(idx, idx):match("%d") then
            decode_error(str, idx, "invalid number")
        end
        while str:sub(idx, idx):match("%d") do
            idx = idx + 1
        end
    end
    return tonumber(str:sub(start, idx - 1)), idx
end

function decode_scanarray(str, idx)
    local arr = {}
    idx = idx + 1
    idx = decode_scanwhite(str, idx)
    if str:sub(idx, idx) == "]" then
        return arr, idx + 1
    end
    while true do
        local val
        val, idx = decode_value(str, idx)
        arr[#arr + 1] = val
        idx = decode_scanwhite(str, idx)
        local c = str:sub(idx, idx)
        if c == "]" then
            return arr, idx + 1
        elseif c == "," then
            idx = decode_scanwhite(str, idx + 1)
        else
            decode_error(str, idx, "expected ',' or ']'")
        end
    end
end

function decode_scanobject(str, idx)
    local obj = {}
    idx = idx + 1
    idx = decode_scanwhite(str, idx)
    if str:sub(idx, idx) == "}" then
        return obj, idx + 1
    end
    while true do
        if str:sub(idx, idx) ~= '"' then
            decode_error(str, idx, "expected string key")
        end
        local key
        key, idx = decode_scanstring(str, idx)
        idx = decode_scanwhite(str, idx)
        if str:sub(idx, idx) ~= ":" then
            decode_error(str, idx, "expected ':'")
        end
        idx = decode_scanwhite(str, idx + 1)
        local val
        val, idx = decode_value(str, idx)
        obj[key] = val
        idx = decode_scanwhite(str, idx)
        local c = str:sub(idx, idx)
        if c == "}" then
            return obj, idx + 1
        elseif c == "," then
            idx = decode_scanwhite(str, idx + 1)
        else
            decode_error(str, idx, "expected ',' or '}'")
        end
    end
end

function decode_value(str, idx)
    idx = decode_scanwhite(str, idx)
    local c = str:sub(idx, idx)
    if c == '"' then
        return decode_scanstring(str, idx)
    elseif c == "{" then
        return decode_scanobject(str, idx)
    elseif c == "[" then
        return decode_scanarray(str, idx)
    elseif c == "t" then
        if str:sub(idx, idx + 3) == "true" then
            return true, idx + 4
        end
        decode_error(str, idx, "invalid literal")
    elseif c == "f" then
        if str:sub(idx, idx + 4) == "false" then
            return false, idx + 5
        end
        decode_error(str, idx, "invalid literal")
    elseif c == "n" then
        if str:sub(idx, idx + 3) == "null" then
            return nil, idx + 4
        end
        decode_error(str, idx, "invalid literal")
    elseif c == "-" or c:match("%d") then
        return decode_scannumber(str, idx)
    else
        decode_error(str, idx, "unexpected character '" .. c .. "'")
    end
end

function json.decode(str)
    if type(str) ~= "string" then
        error("expected string argument")
    end
    local val, idx = decode_value(str, 1)
    idx = decode_scanwhite(str, idx)
    if idx <= #str then
        decode_error(str, idx, "trailing garbage")
    end
    return val
end

json.null = setmetatable({}, {
    __tostring = function() return "null" end,
    __tojson = function() return "null" end,
})

return json
