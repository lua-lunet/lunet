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
  if env and env ~= "" then return env end
  local suffix = "so"
  local ok_popen, uname = pcall(io.popen, "uname -s 2>/dev/null")
  if ok_popen and uname then
    local sys = uname:read("*l") or ""
    uname:close()
    if sys == "Darwin" then suffix = "dylib" end
  end
  local script = debug.getinfo(2, "S").source
  local dir = script:match("^@(.+)/[^/]+$") or "."
  for _, p in ipairs({dir .. "/target/release/liblunet_jsonic." .. suffix, dir .. "/liblunet_jsonic." .. suffix}) do
    local f = io.open(p, "rb")
    if f then f:close(); return p end
  end
  error("lunet.jsonic: cannot find liblunet_jsonic." .. suffix, 3)
end

local _lib
local function lib()
  if not _lib then _lib = ffi.load(find_lib()) end
  return _lib
end

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
  if tag == TAG_NULL then return nullval, pos end
  if tag == TAG_FALSE then return false, pos end
  if tag == TAG_TRUE then return true, pos end
  if tag == TAG_NUMBER then return f64_at(buf, pos), pos + 8 end
  if tag == TAG_STRING then
    local len = u32_at(buf, pos)
    pos = pos + 4
    return ffi.string(buf + pos, len), pos + len
  end
  if tag == TAG_ARRAY then
    local count = u32_at(buf, pos)
    pos = pos + 4
    local arr = {}
    for i = 1, count do
      local v
      v, pos = read_value(buf, pos, nullval)
      arr[i] = v
    end
    return arr, pos
  end
  if tag == TAG_OBJECT then
    local count = u32_at(buf, pos)
    pos = pos + 4
    local obj = {}
    for _ = 1, count do
      local key
      key, pos = read_value(buf, pos, nullval)
      if type(key) ~= "string" then error("lunet.jsonic: object key is not a string", 0) end
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
  if pos ~= len then error("lunet.jsonic: trailing data in tagged buffer", 0) end
  return value
end

local dkjson = assert(loadfile((debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/dkjson-encode-v2.10.lua"))()
local M = dkjson

function M.decode(str, position, nullval)
  assert(type(str) == "string", "lunet.jsonic.decode: expected a string")
  position = position or 1
  nullval = nullval == nil and M.null or nullval
  local input = position > 1 and str:sub(position) or str
  local out = ffi.new("uint8_t*[1]")
  local out_len = ffi.new("size_t[1]")
  local rc = lib().lunet_jsonic_decode(input, #input, out, out_len)
  if rc == JSONIC_ERR_INVAL then return nil, position, "lunet.jsonic: invalid arguments" end
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
  if not ok then error(result, 0) end
  return result, position + #input
end

return M
