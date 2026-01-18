local lunet = require('lunet')
local socket = require('lunet.socket')
local su_mod = require('lunet.su')

-- Wire protocol (v1), length-prefixed frames:
--   u32be frame_len (bytes after this field)
--   u8    version (=1)
--   u8    msg_type (1 = EVAL)
--   u16be flags
--   u32be req_id
--   payload...
--
-- EVAL payload:
--   u32be lua_len
--   bytes lua_source_utf8
--
-- Response payload:
--   u8    status (0=OK, 1=ERR)
--   u32be body_len
--   bytes body (utf8)

local function u32be(n)
  local b1 = math.floor(n / 16777216) % 256
  local b2 = math.floor(n / 65536) % 256
  local b3 = math.floor(n / 256) % 256
  local b4 = n % 256
  return string.char(b1, b2, b3, b4)
end

local function u16be(n)
  local b1 = math.floor(n / 256) % 256
  local b2 = n % 256
  return string.char(b1, b2)
end

local function be_u32(s, off)
  local b1, b2, b3, b4 = s:byte(off, off + 3)
  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

local function read_exact(client, n)
  local parts = {}
  local have = 0
  while have < n do
    local chunk, err = socket.read(client)
    if err then return nil, err end
    if not chunk then return nil, "EOF" end
    parts[#parts + 1] = chunk
    have = have + #chunk
  end
  local data = table.concat(parts)
  if #data == n then return data end
  return data:sub(1, n), data:sub(n + 1)
end

local function read_frame(client, carry)
  carry = carry or ""
  while #carry < 4 do
    local chunk, err = socket.read(client)
    if err then return nil, nil, err end
    if not chunk then return nil, nil, "EOF" end
    carry = carry .. chunk
  end
  local frame_len = be_u32(carry, 1)
  carry = carry:sub(5)
  while #carry < frame_len do
    local chunk, err = socket.read(client)
    if err then return nil, nil, err end
    if not chunk then return nil, nil, "EOF" end
    carry = carry .. chunk
  end
  local frame = carry:sub(1, frame_len)
  carry = carry:sub(frame_len + 1)
  return frame, carry, nil
end

local function write_frame(client, payload)
  return socket.write(client, u32be(#payload) .. payload)
end

local function sandbox_eval(su, src)
  -- Minimal sandbox: no require/package/io/os/ffi/debug.
  local env = {
    assert = assert,
    error = error,
    ipairs = ipairs,
    pairs = pairs,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    string = { byte = string.byte, char = string.char, len = string.len, sub = string.sub, gsub = string.gsub },
    math = { floor = math.floor, abs = math.abs },
    table = { concat = table.concat, insert = table.insert },
    su = su,
  }

  local chunk, err = loadstring(src, "@remote")
  if not chunk then return nil, err end
  setfenv(chunk, env)

  -- Instruction limit to avoid obvious infinite loops.
  local quota = 500000
  local function hook()
    quota = quota - 1
    if quota <= 0 then error("EVAL_QUOTA_EXCEEDED") end
  end
  debug.sethook(hook, "", 1000)
  local ok, res = pcall(chunk)
  debug.sethook()

  if not ok then return nil, tostring(res) end
  if res == nil then return "" end
  return tostring(res)
end

lunet.spawn(function()
  -- Tune socket read buffer so frames aren't fragmented too much.
  socket.set_read_buffer_size(65536)

  -- Storage unit backing directory and address space size.
  local su, err = su_mod.open("./corfu_su", 1024 * 1024) -- 1M addresses ~= 4GB sparse data file
  if not su then error(err) end

  local listener, lerr = socket.listen("tcp", "0.0.0.0", 9000)
  if not listener then error(lerr) end

  while true do
    local client, aerr = socket.accept(listener)
    if client then
      lunet.spawn(function()
        local carry = ""
        while true do
          local frame, next_carry, rerr = read_frame(client, carry)
          if rerr then break end
          carry = next_carry

          if #frame < 8 then
            write_frame(client, string.char(1, 0x81) .. u16be(0) .. u32be(0) .. string.char(1) .. u32be(12) .. "BAD_FRAME")
          else
            local ver = frame:byte(1)
            local typ = frame:byte(2)
            local flags = frame:byte(3) * 256 + frame:byte(4)
            local req_id = be_u32(frame, 5)
            local payload = frame:sub(9)

            if ver ~= 1 then
              local body = "BAD_VERSION"
              local resp = string.char(1, 0x81) .. u16be(flags) .. u32be(req_id) .. string.char(1) .. u32be(#body) .. body
              write_frame(client, resp)
            elseif typ ~= 1 then
              local body = "UNSUPPORTED_TYPE"
              local resp = string.char(1, 0x81) .. u16be(flags) .. u32be(req_id) .. string.char(1) .. u32be(#body) .. body
              write_frame(client, resp)
            else
              if #payload < 4 then
                local body = "BAD_EVAL"
                local resp = string.char(1, 0x81) .. u16be(flags) .. u32be(req_id) .. string.char(1) .. u32be(#body) .. body
                write_frame(client, resp)
              else
                local lua_len = be_u32(payload, 1)
                local lua_src = payload:sub(5, 4 + lua_len)
                local out, e = sandbox_eval(su, lua_src)
                if out then
                  local body = out
                  local resp = string.char(1, 0x81) .. u16be(flags) .. u32be(req_id) .. string.char(0) .. u32be(#body) .. body
                  write_frame(client, resp)
                else
                  local body = e or "EVAL_ERROR"
                  local resp = string.char(1, 0x81) .. u16be(flags) .. u32be(req_id) .. string.char(1) .. u32be(#body) .. body
                  write_frame(client, resp)
                end
              end
            end
          end
        end
        socket.close(client)
      end)
    end
  end
end)

