--[[
  lunet.jsonic: dkjson-style JSON encode/decode.

  The encode path below is lifted from dkjson 2.10 (MIT licensed), with a
  thin wrapper for this module's `opts` convenience and the local `null`
  sentinel.

  Rust side:
    lunet_jsonic_decode(json, len, out, out_len) -> c_int
    lunet_jsonic_free_bytes(p, len)

  Wire format:
    tag byte + payload, little-endian
      0 = null
      1 = false
      2 = true
      3 = number  (8-byte f64)
      4 = string  (u32 length + bytes)
      5 = array   (u32 count + items)
      6 = object  (u32 count + key/value pairs)
]]

local ffi = require("ffi")

ffi.cdef[[
  int lunet_jsonic_decode(const uint8_t* json, size_t len, uint8_t** out, size_t* out_len);
  void lunet_jsonic_free_bytes(uint8_t* p, size_t len);
]]

local JSONIC_OK = 0
local JSONIC_ERR_PARSE = -1
local JSONIC_ERR_INVAL = -2

local TAG_NULL = 0
local TAG_FALSE = 1
local TAG_TRUE = 2
local TAG_NUMBER = 3
local TAG_STRING = 4
local TAG_ARRAY = 5
local TAG_OBJECT = 6

local function find_lib()
  local env = os.getenv("LUNET_JSONIC_LIB")
  if env and env ~= "" then
    return env
  end

  local suffix = "so"
  local ok_popen, uname = pcall(io.popen, "uname -s 2>/dev/null")
  if ok_popen and uname then
    local sys = uname:read("*l") or ""
    uname:close()
    if sys == "Darwin" then
      suffix = "dylib"
    end
  end

  local script = debug.getinfo(2, "S").source
  local dir = script:match("^@(.+)/[^/]+$") or "."
  local candidates = {
    dir .. "/target/release/liblunet_jsonic." .. suffix,
    dir .. "/liblunet_jsonic." .. suffix,
  }
  for _, p in ipairs(candidates) do
    local f = io.open(p, "rb")
    if f then
      f:close()
      return p
    end
  end

  error(
    "lunet.jsonic: cannot find liblunet_jsonic." .. suffix .. "\n" ..
    "  Build it with:  cd ext/jsonic && cargo build --release\n" ..
    "  or set LUNET_JSONIC_LIB=/path/to/liblunet_jsonic." .. suffix,
    3
  )
end

local _lib
local function lib()
  if not _lib then
    _lib = ffi.load(find_lib())
  end
  return _lib
end

local M = {}

M.null = setmetatable({}, {
  __tostring = function() return "null" end,
})

local function u32_at(buf, pos)
  local tmp = ffi.new("uint32_t[1]")
  ffi.copy(tmp, buf + pos, 4)
  return tonumber(tmp[0])
end

local function f64_at(buf, pos)
  local tmp = ffi.new("double[1]")
  ffi.copy(tmp, buf + pos, 8)
  return tmp[0]
end

local function read_value(buf, pos, nullval)
  local tag = tonumber(buf[pos])
  pos = pos + 1

  if tag == TAG_NULL then
    return nullval, pos
  elseif tag == TAG_FALSE then
    return false, pos
  elseif tag == TAG_TRUE then
    return true, pos
  elseif tag == TAG_NUMBER then
    return f64_at(buf, pos), pos + 8
  elseif tag == TAG_STRING then
    local len = u32_at(buf, pos)
    pos = pos + 4
    return ffi.string(buf + pos, len), pos + len
  elseif tag == TAG_ARRAY then
    local count = u32_at(buf, pos)
    pos = pos + 4
    local arr = {}
    for i = 1, count do
      local v
      v, pos = read_value(buf, pos, nullval)
      arr[i] = v
    end
    return arr, pos
  elseif tag == TAG_OBJECT then
    local count = u32_at(buf, pos)
    pos = pos + 4
    local obj = {}
    for _ = 1, count do
      local key
      key, pos = read_value(buf, pos, nullval)
      if type(key) ~= "string" then
        error("lunet.jsonic: object key is not a string", 0)
      end
      local value
      value, pos = read_value(buf, pos, nullval)
      obj[key] = value
    end
    return obj, pos
  end

  error("lunet.jsonic: invalid tagged buffer", 0)
end

local function decode_buffer(ptr, len, nullval)
  local buf = ffi.cast("const uint8_t*", ptr)
  local value, pos = read_value(buf, 0, nullval)
  if pos ~= len then
    error("lunet.jsonic: trailing data in tagged buffer", 0)
  end
  return value
end

function M.decode(str, position, nullval)
  assert(type(str) == "string", "lunet.jsonic.decode: expected a string")
  position = position or 1
  nullval = nullval == nil and M.null or nullval

  local input = position > 1 and str:sub(position) or str
  local out = ffi.new("uint8_t*[1]")
  local out_len = ffi.new("size_t[1]")
  local rc = lib().lunet_jsonic_decode(input, #input, out, out_len)

  if rc == JSONIC_ERR_INVAL then
    return nil, position, "lunet.jsonic: invalid arguments"
  end

  if rc ~= JSONIC_OK then
    local msg = "parse error"
    if out[0] ~= nil then
      msg = ffi.string(out[0], tonumber(out_len[0]))
      lib().lunet_jsonic_free_bytes(out[0], out_len[0])
    end
    return nil, position, msg
  end

  local ok, result = pcall(decode_buffer, out[0], tonumber(out_len[0]), nullval)
  lib().lunet_jsonic_free_bytes(out[0], out_len[0])
  if not ok then
    error(result, 0)
  end
  return result, position + #input
end

local pairs, type, tostring, tonumber, getmetatable, setmetatable =
      pairs, type, tostring, tonumber, getmetatable, setmetatable
local error, require, pcall, select = error, require, pcall, select
local floor, huge = math.floor, math.huge
local strrep, gsub, strsub, strbyte, strchar, strfind, strlen, strformat =
      string.rep, string.gsub, string.sub, string.byte, string.char,
      string.find, string.len, string.format
local strmatch = string.match
local concat = table.concat
local sort = table.sort

local json = M
json.version = "dkjson 2.10"

local jsonlpeg = {}

local _ENV = nil

pcall (function()
  local debmeta = require "debug".getmetatable
  if debmeta then getmetatable = debmeta end
end)

json.null = setmetatable ({}, {
  __tojson = function () return "null" end
})

local function isarray (tbl)
  local max, n, arraylen = 0, 0, 0
  for k,v in pairs (tbl) do
    if k == 'n' and type(v) == 'number' then
      arraylen = v
      if v > max then
        max = v
      end
    else
      if type(k) ~= 'number' or k < 1 or floor(k) ~= k then
        return false
      end
      if k > max then
        max = k
      end
      n = n + 1
    end
  end
  if max > 10 and max > arraylen and max > n * 2 then
    return false
  end
  return true, max
end

local escapecodes = {
  ["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n",  ["\r"] = "\\r",  ["\t"] = "\\t"
}

local function escapeutf8 (uchar)
  local value = escapecodes[uchar]
  if value then
    return value
  end
  local a, b, c, d = strbyte (uchar, 1, 4)
  a, b, c, d = a or 0, b or 0, c or 0, d or 0
  if a <= 0x7f then
    value = a
  elseif 0xc0 <= a and a <= 0xdf and b >= 0x80 then
    value = (a - 0xc0) * 0x40 + b - 0x80
  elseif 0xe0 <= a and a <= 0xef and b >= 0x80 and c >= 0x80 then
    value = ((a - 0xe0) * 0x40 + b - 0x80) * 0x40 + c - 0x80
  elseif 0xf0 <= a and a <= 0xf7 and b >= 0x80 and c >= 0x80 and d >= 0x80 then
    value = (((a - 0xf0) * 0x40 + b - 0x80) * 0x40 + c - 0x80) * 0x40 + d - 0x80
  else
    return ""
  end
  if value <= 0xffff then
    return strformat ("\\u%.4x", value)
  elseif value <= 0x10ffff then
    value = value - 0x10000
    local highsur, lowsur = 0xD800 + floor (value/0x400), 0xDC00 + (value % 0x400)
    return strformat ("\\u%.4x\\u%.4x", highsur, lowsur)
  else
    return ""
  end
end

local function fsub (str, pattern, repl)
  if strfind (str, pattern) then
    return gsub (str, pattern, repl)
  else
    return str
  end
end

local function quotestring (value)
  value = fsub (value, "[%z\1-\31\"\\\127]", escapeutf8)
  if strfind (value, "[\194\216\220\225\226\239]") then
    value = fsub (value, "\194[\128-\159\173]", escapeutf8)
    value = fsub (value, "\216[\128-\132]", escapeutf8)
    value = fsub (value, "\220\143", escapeutf8)
    value = fsub (value, "\225\158[\180\181]", escapeutf8)
    value = fsub (value, "\226\128[\140-\143\168-\175]", escapeutf8)
    value = fsub (value, "\226\129[\160-\175]", escapeutf8)
    value = fsub (value, "\239\187\191", escapeutf8)
    value = fsub (value, "\239\191[\176-\191]", escapeutf8)
  end
  return '"' .. value .. '"'
end
json.quotestring = quotestring

local function replace(str, o, n)
  local i, j = strfind (str, o, 1, true)
  if i then
    return strsub(str, 1, i-1) .. n .. strsub(str, j+1, -1)
  else
    return str
  end
end

local decpoint, numfilter

local function updatedecpoint ()
  decpoint = strmatch(tostring(0.5), "([^05+])")
  numfilter = "[^0-9%-%+eE" .. gsub(decpoint, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "]+"
end

updatedecpoint()

local function num2str (num)
  return replace(fsub(tostring(num), numfilter, ""), decpoint, ".")
end

local function addnewline2 (level, buffer, buflen)
  buffer[buflen+1] = "\n"
  buffer[buflen+2] = strrep ("  ", level)
  buflen = buflen + 2
  return buflen
end

function json.addnewline (state)
  if state.indent then
    state.bufferlen = addnewline2 (state.level or 0,
                           state.buffer, state.bufferlen or #(state.buffer))
  end
end

local encode2

local function addpair (key, value, prev, indent, level, buffer, buflen, tables, globalorder, state)
  local kt = type (key)
  if kt ~= 'string' and kt ~= 'number' then
    return nil, "type '" .. kt .. "' is not supported as a key by JSON."
  end
  if prev then
    buflen = buflen + 1
    buffer[buflen] = ","
  end
  if indent then
    buflen = addnewline2 (level, buffer, buflen)
  end
  buffer[buflen+1] = quotestring (key)
  buffer[buflen+2] = ":"
  return encode2 (value, indent, level, buffer, buflen + 2, tables, globalorder, state)
end

local function appendcustom(res, buffer, state)
  local buflen = state.bufferlen
  if type (res) == 'string' then
    buflen = buflen + 1
    buffer[buflen] = res
  end
  return buflen
end

local function exception(reason, value, state, buffer, buflen, defaultmessage)
  defaultmessage = defaultmessage or reason
  local handler = state.exception
  if not handler then
    return nil, defaultmessage
  else
    state.bufferlen = buflen
    local ret, msg = handler (reason, value, state, defaultmessage)
    if not ret then return nil, msg or defaultmessage end
    return appendcustom(ret, buffer, state)
  end
end

function json.encodeexception(reason, value, state, defaultmessage)
  return quotestring("<" .. defaultmessage .. ">")
end

encode2 = function (value, indent, level, buffer, buflen, tables, globalorder, state)
  local valtype = type (value)
  local valmeta = getmetatable (value)
  valmeta = type (valmeta) == 'table' and valmeta
  local valtojson = valmeta and valmeta.__tojson
  if valtojson then
    if tables[value] then
      return exception('reference cycle', value, state, buffer, buflen)
    end
    tables[value] = true
    state.bufferlen = buflen
    local ret, msg = valtojson (value, state)
    if not ret then return exception('custom encoder failed', value, state, buffer, buflen, msg) end
    tables[value] = nil
    buflen = appendcustom(ret, buffer, state)
  elseif value == nil then
    buflen = buflen + 1
    buffer[buflen] = "null"
  elseif valtype == 'number' then
    local s
    if value ~= value or value >= huge or -value >= huge then
      s = "null"
    else
      s = num2str (value)
    end
    buflen = buflen + 1
    buffer[buflen] = s
  elseif valtype == 'boolean' then
    buflen = buflen + 1
    buffer[buflen] = value and "true" or "false"
  elseif valtype == 'string' then
    buflen = buflen + 1
    buffer[buflen] = quotestring (value)
  elseif valtype == 'table' then
    if tables[value] then
      return exception('reference cycle', value, state, buffer, buflen)
    end
    tables[value] = true
    level = level + 1
    local isa, n = isarray (value)
    if n == 0 and valmeta and valmeta.__jsontype == 'object' then
      isa = false
    end
    local msg
    if isa then
      buflen = buflen + 1
      buffer[buflen] = "["
      for i = 1, n do
        buflen, msg = encode2 (value[i], indent, level, buffer, buflen, tables, globalorder, state)
        if not buflen then return nil, msg end
        if i < n then
          buflen = buflen + 1
          buffer[buflen] = ","
        end
      end
      buflen = buflen + 1
      buffer[buflen] = "]"
    else
      local prev = false
      buflen = buflen + 1
      buffer[buflen] = "{"
      local order = valmeta and valmeta.__jsonorder or globalorder
      if order then
        local used = {}
        n = #order
        for i = 1, n do
          local k = order[i]
          local v = value[k]
          if v ~= nil then
            used[k] = true
            buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
            if not buflen then return nil, msg end
            prev = true
          end
        end
        for k,v in pairs (value) do
          if not used[k] then
            buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
            if not buflen then return nil, msg end
            prev = true
          end
        end
      else
        for k,v in pairs (value) do
          buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
          if not buflen then return nil, msg end
          prev = true
        end
      end
      if indent then
        buflen = addnewline2 (level - 1, buffer, buflen)
      end
      buflen = buflen + 1
      buffer[buflen] = "}"
    end
    tables[value] = nil
  else
    return exception ('unsupported type', value, state, buffer, buflen,
      "type '" .. valtype .. "' is not supported by JSON.")
  end
  return buflen
end

local function encode_top_level(value, state)
  state = state or {}
  local oldbuffer = state.buffer
  local buffer = oldbuffer or {}
  state.buffer = buffer
  updatedecpoint()
  local ret, msg = encode2 (value, state.indent, state.level or 0,
                   buffer, state.bufferlen or 0, state.tables or {}, state.keyorder, state)
  if not ret then
    error (msg, 2)
  elseif oldbuffer == buffer then
    state.bufferlen = ret
    return true
  else
    state.bufferlen = nil
    state.buffer = nil
    return concat (buffer)
  end
end

local function sorted_keyorder(value)
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = k
  end
  sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

function M.encode(value, opts)
  local state = opts or {}
  if state.sorted_keys and type(value) == "table" and state.keyorder == nil then
    state.keyorder = sorted_keyorder(value)
  end
  return encode_top_level(value, state)
end

M.quotestring = quotestring
M.addnewline = json.addnewline
M.encodeexception = json.encodeexception

return M
