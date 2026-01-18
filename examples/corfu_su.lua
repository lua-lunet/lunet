local lunet = require("lunet")
local socket = require("lunet.socket")
local fs = require("lunet.fs")
local bit = require("bit")

local BLOCK_SIZE = 4096
local VERSION = 1

local MSG_WRITE = 1
local MSG_READ = 2
local MSG_PING = 3

local STATUS_OK = 0
local STATUS_ALREADY_WRITTEN = 1
local STATUS_NOT_WRITTEN = 2
local STATUS_BAD_REQUEST = 3
local STATUS_LUA_ERROR = 4
local STATUS_BAD_SIZE = 5
local STATUS_IO_ERROR = 6

local MAX_FRAME_SIZE = 1024 * 1024
local MAX_ADDRESS = 0xFFFFFFFF
local MAX_SAFE_OFFSET = 9007199254740991

local function pack_u16(n)
  return string.char(bit.band(bit.rshift(n, 8), 0xff), bit.band(n, 0xff))
end

local function pack_u32(n)
  return string.char(
    bit.band(bit.rshift(n, 24), 0xff),
    bit.band(bit.rshift(n, 16), 0xff),
    bit.band(bit.rshift(n, 8), 0xff),
    bit.band(n, 0xff)
  )
end

local function pack_u64(n)
  local hi = math.floor(n / 4294967296)
  local lo = n - (hi * 4294967296)
  return pack_u32(hi) .. pack_u32(lo)
end

local function unpack_u16(s, i)
  local b1, b2 = s:byte(i, i + 1)
  if not b2 then
    return nil
  end
  return b1 * 256 + b2
end

local function unpack_u32(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  if not b4 then
    return nil
  end
  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

local function unpack_u64(s, i)
  local hi = unpack_u32(s, i)
  local lo = unpack_u32(s, i + 4)
  if not hi or not lo then
    return nil
  end
  return hi * 4294967296 + lo
end

local function read_bytes(state, client, count)
  while #state.buffer < count do
    local chunk, err = socket.read(client)
    if not chunk then
      return nil, err or "eof"
    end
    state.buffer = state.buffer .. chunk
  end
  local out = state.buffer:sub(1, count)
  state.buffer = state.buffer:sub(count + 1)
  return out
end

local function read_frame(state, client)
  local header, err = read_bytes(state, client, 4)
  if not header then
    return nil, err
  end
  local total_len = unpack_u32(header, 1)
  if not total_len or total_len < 8 or total_len > MAX_FRAME_SIZE then
    return nil, "invalid frame length"
  end
  local body, body_err = read_bytes(state, client, total_len)
  if not body then
    return nil, body_err
  end
  local version = body:byte(1)
  local msg_type = body:byte(2)
  local flags = unpack_u16(body, 3) or 0
  local request_id = unpack_u32(body, 5) or 0
  local payload = body:sub(9)
  return {
    version = version,
    msg_type = msg_type,
    flags = flags,
    request_id = request_id,
    payload = payload,
  }
end

local function send_frame(client, msg_type, request_id, payload)
  local body = string.char(VERSION, msg_type) .. pack_u16(0) .. pack_u32(request_id) .. payload
  local frame = pack_u32(#body) .. body
  local err = socket.write(client, frame)
  if err then
    return nil, err
  end
  return true
end

local function open_rw(path)
  local fd, err = fs.open(path, "r+")
  if fd then
    return fd
  end
  return fs.open(path, "w+")
end

local function eval_lua(source, address)
  local chunk, err = loadstring(source, "client")
  if not chunk then
    return nil, STATUS_LUA_ERROR, err
  end
  local env = {
    address = address,
    BLOCK_SIZE = BLOCK_SIZE,
    assert = assert,
    error = error,
    ipairs = ipairs,
    math = math,
    next = next,
    pairs = pairs,
    string = string,
    table = table,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    bit = bit,
  }
  env._G = env
  setfenv(chunk, env)
  local ok, result = pcall(chunk)
  if not ok then
    return nil, STATUS_LUA_ERROR, tostring(result)
  end
  if type(result) ~= "string" then
    return nil, STATUS_BAD_REQUEST, "script must return string"
  end
  if #result ~= BLOCK_SIZE then
    return nil, STATUS_BAD_SIZE, "script must return 4096 bytes"
  end
  return result, STATUS_OK, nil
end

lunet.spawn(function()
  local host = (arg and arg[1]) or "127.0.0.1"
  local port = tonumber((arg and arg[2]) or "") or 9000
  local data_path = (arg and arg[3]) or "corfu.data"
  local bitmap_path = (arg and arg[4]) or "corfu.bitmap"

  local data_fd, data_err = open_rw(data_path)
  if not data_fd then
    error("failed to open data file: " .. tostring(data_err))
  end

  local bitmap_fd, bitmap_err = open_rw(bitmap_path)
  if not bitmap_fd then
    error("failed to open bitmap file: " .. tostring(bitmap_err))
  end

  local bitmap_cache = {}
  local inflight = {}

  local function load_bitmap_byte(byte_index)
    local cached = bitmap_cache[byte_index]
    if cached ~= nil then
      return cached
    end
    local data, err = fs.read(bitmap_fd, 1, byte_index)
    if err then
      return nil, err
    end
    local value = 0
    if data and #data == 1 then
      value = data:byte(1)
    end
    bitmap_cache[byte_index] = value
    return value
  end

  local function bitmap_get(address)
    local byte_index = math.floor(address / 8)
    local bit_index = address % 8
    local value, err = load_bitmap_byte(byte_index)
    if value == nil then
      return nil, err
    end
    return bit.band(value, bit.lshift(1, bit_index)) ~= 0
  end

  local function bitmap_set(address)
    local byte_index = math.floor(address / 8)
    local bit_index = address % 8
    local value, err = load_bitmap_byte(byte_index)
    if value == nil then
      return nil, err
    end
    local mask = bit.lshift(1, bit_index)
    local new_value = bit.bor(value, mask)
    if new_value == value then
      return true
    end
    bitmap_cache[byte_index] = new_value
    local written, write_err = fs.write(bitmap_fd, string.char(new_value), byte_index)
    if write_err then
      return nil, write_err
    end
    if written ~= 1 then
      return nil, "short bitmap write"
    end
    return true
  end

  local function validate_address(address)
    if type(address) ~= "number" then
      return nil, "address must be number"
    end
    if address < 0 or address ~= math.floor(address) then
      return nil, "address must be integer"
    end
    if address > MAX_ADDRESS then
      return nil, "address out of range"
    end
    local offset = address * BLOCK_SIZE
    if offset > MAX_SAFE_OFFSET - BLOCK_SIZE then
      return nil, "address too large"
    end
    return offset
  end

  local function write_block(address, data)
    if inflight[address] then
      return nil, "BUSY"
    end
    inflight[address] = true
    local written, written_err = bitmap_get(address)
    if written_err then
      inflight[address] = nil
      return nil, written_err
    end
    if written then
      inflight[address] = nil
      return nil, "ALREADY_WRITTEN"
    end
    local offset = address * BLOCK_SIZE
    local bytes, write_err = fs.write(data_fd, data, offset)
    if write_err then
      inflight[address] = nil
      return nil, write_err
    end
    if bytes ~= BLOCK_SIZE then
      inflight[address] = nil
      return nil, "short data write"
    end
    local ok, mark_err = bitmap_set(address)
    inflight[address] = nil
    if not ok then
      return nil, mark_err
    end
    return true
  end

  local function read_block(address)
    local written, written_err = bitmap_get(address)
    if written_err then
      return nil, written_err
    end
    if not written then
      return nil, "NOT_WRITTEN"
    end
    local offset = address * BLOCK_SIZE
    local data, read_err = fs.read(data_fd, BLOCK_SIZE, offset)
    if read_err then
      return nil, read_err
    end
    if not data or #data ~= BLOCK_SIZE then
      return nil, "short data read"
    end
    return data
  end

  local function send_error(client, msg_type, request_id, address, status, err)
    local message = err or ""
    local payload = pack_u64(address) .. string.char(status) .. pack_u32(#message) .. message
    return send_frame(client, msg_type, request_id, payload)
  end

  local function send_write_ok(client, request_id, address)
    local payload = pack_u64(address) .. string.char(STATUS_OK) .. pack_u32(0)
    return send_frame(client, MSG_WRITE, request_id, payload)
  end

  local function send_read_ok(client, request_id, address, data)
    local payload = pack_u64(address) .. string.char(STATUS_OK) .. data
    return send_frame(client, MSG_READ, request_id, payload)
  end

  local function handle_write(client, request_id, payload)
    if #payload < 12 then
      return send_error(client, MSG_WRITE, request_id, 0, STATUS_BAD_REQUEST, "payload too short")
    end
    local address = unpack_u64(payload, 1)
    local lua_len = unpack_u32(payload, 9)
    if not address or not lua_len then
      return send_error(client, MSG_WRITE, request_id, 0, STATUS_BAD_REQUEST, "invalid payload")
    end
    if 12 + lua_len ~= #payload then
      return send_error(client, MSG_WRITE, request_id, address, STATUS_BAD_REQUEST, "invalid lua length")
    end
    local _, addr_err = validate_address(address)
    if addr_err then
      return send_error(client, MSG_WRITE, request_id, address, STATUS_BAD_REQUEST, addr_err)
    end
    local script = payload:sub(13, 12 + lua_len)
    local data, eval_status, eval_err = eval_lua(script, address)
    if not data then
      return send_error(client, MSG_WRITE, request_id, address, eval_status, eval_err)
    end
    local ok, write_err = write_block(address, data)
    if not ok then
      local status = STATUS_IO_ERROR
      if write_err == "ALREADY_WRITTEN" or write_err == "BUSY" then
        status = STATUS_ALREADY_WRITTEN
      end
      return send_error(client, MSG_WRITE, request_id, address, status, write_err)
    end
    return send_write_ok(client, request_id, address)
  end

  local function handle_read(client, request_id, payload)
    if #payload < 8 then
      return send_error(client, MSG_READ, request_id, 0, STATUS_BAD_REQUEST, "payload too short")
    end
    local address = unpack_u64(payload, 1)
    if not address then
      return send_error(client, MSG_READ, request_id, 0, STATUS_BAD_REQUEST, "invalid payload")
    end
    local _, addr_err = validate_address(address)
    if addr_err then
      return send_error(client, MSG_READ, request_id, address, STATUS_BAD_REQUEST, addr_err)
    end
    local data, read_err = read_block(address)
    if not data then
      local status = STATUS_IO_ERROR
      if read_err == "NOT_WRITTEN" then
        status = STATUS_NOT_WRITTEN
      end
      return send_error(client, MSG_READ, request_id, address, status, read_err)
    end
    return send_read_ok(client, request_id, address, data)
  end

  local listener, listen_err = socket.listen("tcp", host, port)
  if not listener then
    error("failed to listen: " .. tostring(listen_err))
  end

  socket.set_read_buffer_size(65536)

  while true do
    local client = socket.accept(listener)
    if client then
      lunet.spawn(function()
        local state = {buffer = ""}
        while true do
          local frame, frame_err = read_frame(state, client)
          if not frame then
            break
          end
          if frame.version ~= VERSION then
            send_error(client, frame.msg_type or MSG_PING, frame.request_id or 0, 0, STATUS_BAD_REQUEST, "version mismatch")
            break
          end
          if frame.msg_type == MSG_WRITE then
            local ok = handle_write(client, frame.request_id, frame.payload)
            if not ok then
              break
            end
          elseif frame.msg_type == MSG_READ then
            local ok = handle_read(client, frame.request_id, frame.payload)
            if not ok then
              break
            end
          elseif frame.msg_type == MSG_PING then
            local ok = send_frame(client, MSG_PING, frame.request_id, string.char(STATUS_OK))
            if not ok then
              break
            end
          else
            send_error(client, frame.msg_type or MSG_PING, frame.request_id or 0, 0, STATUS_BAD_REQUEST, "unknown message")
            break
          end
        end
        socket.close(client)
      end)
    end
  end
end)
