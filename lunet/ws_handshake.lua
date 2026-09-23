local ffi = require("ffi")
local bit = require("bit")

local M = {}

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function safe_cdef(def)
  local ok, err = pcall(ffi.cdef, def)
  if ok then
    return true
  end
  if type(err) == "string" and err:find("duplicate declaration", 1, true) then
    return true
  end
  return nil, err
end

local function b64encode(data)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local a = data:byte(i) or 0
    local b = data:byte(i + 1) or 0
    local c = data:byte(i + 2) or 0
    local n = bit.bor(bit.lshift(a, 16), bit.lshift(b, 8), c)
    local c1 = bit.band(bit.rshift(n, 18), 0x3f) + 1
    local c2 = bit.band(bit.rshift(n, 12), 0x3f) + 1
    local c3 = bit.band(bit.rshift(n, 6), 0x3f) + 1
    local c4 = bit.band(n, 0x3f) + 1
    out[#out + 1] = alphabet:sub(c1, c1)
    out[#out + 1] = alphabet:sub(c2, c2)
    if i + 1 <= len then
      out[#out + 1] = alphabet:sub(c3, c3)
    else
      out[#out + 1] = "="
    end
    if i + 2 <= len then
      out[#out + 1] = alphabet:sub(c4, c4)
    else
      out[#out + 1] = "="
    end
    i = i + 3
  end
  return table.concat(out)
end

local function new_sha1()
  local ok, jit_mod = pcall(require, "jit")
  local os_name = ok and jit_mod and jit_mod.os or ""

  if os_name == "OSX" then
    local ok_cdef, cdef_err = safe_cdef([[
      unsigned char *CC_SHA1(const void *data, unsigned int len, unsigned char *md);
    ]])
    if not ok_cdef then
      return nil, "CC_SHA1 cdef failed: " .. tostring(cdef_err)
    end
    return function(input)
      local out = ffi.new("uint8_t[20]")
      if ffi.C.CC_SHA1(input, #input, out) == nil then
        return nil, "CC_SHA1 failed"
      end
      return ffi.string(out, 20)
    end
  end

  local ok_cdef, cdef_err = safe_cdef([[
    unsigned char *SHA1(const unsigned char *d, size_t n, unsigned char *md);
  ]])
  if not ok_cdef then
    return nil, "SHA1 cdef failed: " .. tostring(cdef_err)
  end
  local candidates = {
    "crypto",
    "libcrypto",
    "libcrypto.so",
    "libcrypto.dylib",
    "libcrypto.dll",
    "libcrypto-3-x64",
    "libcrypto-1_1-x64",
  }
  local lib = nil
  for _, name in ipairs(candidates) do
    local ok_load, loaded = pcall(ffi.load, name)
    if ok_load and loaded then
      local ok_probe = pcall(function()
        return loaded.SHA1
      end)
      if ok_probe then
        lib = loaded
        break
      end
    end
  end
  if not lib then
    return nil, "SHA1 backend unavailable (tried CommonCrypto/libcrypto)"
  end
  return function(input)
    local out = ffi.new("uint8_t[20]")
    if lib.SHA1(input, #input, out) == nil then
      return nil, "SHA1 failed"
    end
    return ffi.string(out, 20)
  end
end

local sha1, sha1_init_err = new_sha1()

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_headers(raw_headers)
  local headers = {}
  for line in raw_headers:gmatch("([^\r\n]+)") do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k and v then
      headers[k:lower()] = trim(v)
    end
  end
  return headers
end

function M.compute_accept(sec_websocket_key)
  if not sha1 then
    return nil, sha1_init_err or "sha1 unavailable"
  end
  local digest, err = sha1(sec_websocket_key .. GUID)
  if not digest then
    return nil, err
  end
  return b64encode(digest)
end

function M.parse_http_upgrade_request(raw)
  local head, leftover = raw:match("^(.-\r\n\r\n)(.*)$")
  if not head then
    return nil, "incomplete request"
  end
  local req_line, rest = head:match("^([^\r\n]+)\r\n(.*)\r\n\r\n$")
  if not req_line then
    return nil, "invalid request line"
  end
  local method, path, version = req_line:match("^(%u+)%s+([^%s]+)%s+(HTTP/%d%.%d)$")
  if not method then
    return nil, "invalid request line"
  end
  local headers = parse_headers(rest)
  return {
    method = method,
    path = path,
    version = version,
    headers = headers,
    _leftover = leftover or "",
    _raw_head = head,
  }, nil
end

function M.is_upgrade_request(req)
  if type(req) ~= "table" or type(req.headers) ~= "table" then
    return false
  end
  if req.method ~= "GET" then
    return false
  end
  local upgrade = (req.headers["upgrade"] or ""):lower()
  if upgrade ~= "websocket" then
    return false
  end
  local connection = (req.headers["connection"] or ""):lower()
  if not connection:find("upgrade", 1, true) then
    return false
  end
  if not req.headers["sec-websocket-key"] then
    return false
  end
  local version = req.headers["sec-websocket-version"]
  if version and version ~= "13" then
    return false
  end
  return true
end

function M.build_upgrade_response(req, opts)
  opts = opts or {}
  local key = req.headers["sec-websocket-key"]
  local accept, err = M.compute_accept(key)
  if not accept then
    return nil, err
  end
  local parts = {
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. accept,
  }
  if opts.subprotocol and #opts.subprotocol > 0 then
    parts[#parts + 1] = "Sec-WebSocket-Protocol: " .. opts.subprotocol
  end
  return table.concat(parts, "\r\n") .. "\r\n\r\n", nil
end

return M