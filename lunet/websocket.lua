local socket = require("lunet.socket")
local native = require("lunet._websocket")
local handshake = require("lunet.ws_handshake")
local registry = require("lunet.ws_registry")

local M = {}

M.TEXT = native.TEXT or 1
M.BINARY = native.BINARY or 2
M.CLOSE = native.CLOSE or 8
M.PING = native.PING or 9
M.PONG = native.PONG or 10

local function normalize_max_message_size(value)
  if value == nil then
    return nil
  end
  if type(value) ~= "number" then
    return nil, "max_message_size must be a number"
  end
  if value <= 0 or value ~= math.floor(value) then
    return nil, "max_message_size must be a positive integer"
  end
  return value
end

local function write_all(client, payload)
  if payload and #payload > 0 then
    local err = socket.write(client, payload)
    if err then
      return nil, err
    end
  end
  return true
end

local function new_conn(listener, client, native_ctx, initial_chunk)
  local conn = {
    _listener = listener,
    _sock = client,
    _native = native_ctx,
    _pending = initial_chunk or "",
    closed = false,
  }
  conn.id = registry.next_id()
  registry.register(listener, conn)
  return conn
end

local function ensure_conn(conn)
  if type(conn) ~= "table" or not conn._sock or not conn._native or conn.closed then
    return nil, "invalid websocket connection"
  end
  return conn
end

local function close_internal(conn, code, reason, send_close_frame)
  if conn.closed then
    return true
  end
  if send_close_frame ~= false then
    local frame, qerr = native._queue_close(conn._native, code or 1000, reason or "")
    if frame then
      local werr = socket.write(conn._sock, frame)
      if werr then
        native._free(conn._native)
        socket.close(conn._sock)
        conn.closed = true
        registry.unregister(conn._listener, conn)
        return nil, werr
      end
    elseif qerr then
      native._free(conn._native)
      socket.close(conn._sock)
      conn.closed = true
      registry.unregister(conn._listener, conn)
      return nil, qerr
    end
  end
  native._free(conn._native)
  socket.close(conn._sock)
  conn.closed = true
  registry.unregister(conn._listener, conn)
  return true
end

function M.read_http_request(client, max_header_bytes)
  local max_bytes = max_header_bytes or 65536
  local buf = ""
  while true do
    local head_end = buf:find("\r\n\r\n", 1, true)
    if head_end then
      local req, perr = handshake.parse_http_upgrade_request(buf)
      if not req then
        return nil, perr
      end
      return req, nil
    end
    if #buf > max_bytes then
      return nil, "request headers too large"
    end
    local chunk, err = socket.read(client)
    if not chunk then
      return nil, err or "connection closed"
    end
    buf = buf .. chunk
  end
end

function M.is_upgrade_request(req)
  return handshake.is_upgrade_request(req)
end

function M.listen(protocol, host, port, opts)
  opts = opts or {}
  local max_message_size, size_err = normalize_max_message_size(opts.max_message_size)
  if size_err then
    return nil, size_err
  end
  local listener_handle, err = socket.listen(protocol, host, port)
  if not listener_handle then
    return nil, err
  end
  local listener = {
    _sock = listener_handle,
    protocol = protocol,
    host = host,
    port = port,
    _registry = opts.registry and registry.new_listener_registry() or nil,
    _max_message_size = max_message_size,
  }
  return listener, nil
end

function M.upgrade(client, req, opts)
  opts = opts or {}
  local max_message_size, size_err = normalize_max_message_size(opts.max_message_size)
  if size_err then
    return nil, size_err
  end
  local request = req
  if not request then
    local r, err = M.read_http_request(client, opts.max_header_bytes)
    if not r then
      return nil, err
    end
    request = r
  end

  if not handshake.is_upgrade_request(request) then
    return nil, "not a websocket upgrade request"
  end

  local response, rerr = handshake.build_upgrade_response(request, opts)
  if not response then
    return nil, rerr
  end
  local werr = socket.write(client, response)
  if werr then
    return nil, werr
  end

  local native_ctx, nerr = native._new(max_message_size)
  if not native_ctx then
    return nil, nerr
  end

  local conn = new_conn(opts.listener, client, native_ctx, request._leftover or "")
  return conn, nil
end

function M.accept(listener, opts)
  if type(listener) ~= "table" or not listener._sock then
    return nil, "invalid websocket listener"
  end
  opts = opts or {}

  local client, err = socket.accept(listener._sock)
  if not client then
    return nil, err
  end

  local req, rerr = M.read_http_request(client, opts.max_header_bytes)
  if not req then
    socket.close(client)
    return nil, rerr
  end

  local conn, uerr = M.upgrade(client, req, {
    listener = listener,
    subprotocol = opts.subprotocol,
    max_header_bytes = opts.max_header_bytes,
    max_message_size = (opts.max_message_size ~= nil) and opts.max_message_size or listener._max_message_size,
  })
  if not conn then
    local _ = socket.write(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
    socket.close(client)
    return nil, uerr
  end
  return conn, nil
end

function M.recv(conn)
  local c, cerr = ensure_conn(conn)
  if not c then
    return nil, nil, cerr
  end

  local function feed(chunk)
    local msg, opcode, outbound, closed, err = native._feed(c._native, chunk)
    if err then
      return nil, nil, err
    end
    local ok, werr = write_all(c._sock, outbound)
    if not ok then
      return nil, nil, werr
    end
    if closed then
      close_internal(c, 1000, "", false)
      return nil, nil, "connection closed"
    end
    if msg ~= nil then
      return msg, opcode, nil
    end
    return nil, nil, nil
  end

  if c._pending and #c._pending > 0 then
    local msg, opcode, err = feed(c._pending)
    c._pending = ""
    if err then
      return nil, nil, err
    end
    if msg ~= nil then
      return msg, opcode, nil
    end
  end

  while true do
    local chunk, err = socket.read(c._sock)
    if not chunk then
      close_internal(c, 1000, "")
      return nil, nil, err or "connection closed"
    end
    local msg, opcode, ferr = feed(chunk)
    if ferr then
      return nil, nil, ferr
    end
    if msg ~= nil then
      return msg, opcode, nil
    end
  end
end

function M.send(conn, data, opcode)
  local c, cerr = ensure_conn(conn)
  if not c then
    return nil, cerr
  end
  local frame, qerr = native._queue_msg(c._native, data, opcode or M.TEXT)
  if not frame and qerr then
    return nil, qerr
  end
  return write_all(c._sock, frame)
end

function M.ping(conn, data)
  local c, cerr = ensure_conn(conn)
  if not c then
    return nil, cerr
  end
  local frame, qerr = native._queue_ping(c._native, data or "")
  if not frame and qerr then
    return nil, qerr
  end
  return write_all(c._sock, frame)
end

function M.close(conn, code, reason)
  local c, cerr = ensure_conn(conn)
  if not c then
    return nil, cerr
  end
  return close_internal(c, code, reason)
end

function M.id(conn)
  if type(conn) ~= "table" then
    return nil
  end
  return conn.id
end

function M.connections(listener)
  return registry.listener_connections(listener)
end

function M.broadcast(listener, data, opcode)
  local conns = registry.listener_connections(listener)
  local sent = 0
  local first_err = nil
  for _, conn in ipairs(conns) do
    local ok, err = M.send(conn, data, opcode)
    if ok then
      sent = sent + 1
    elseif not first_err then
      first_err = err
    end
  end
  return sent, first_err
end

function M.enable_global_registry()
  registry.enable_global_registry()
end

M.global_registry = {
  find_by_id = function(id)
    return registry.global_find(id)
  end,
  broadcast_all = function(data, opcode)
    local conns = registry.global_connections()
    local sent = 0
    local first_err = nil
    for _, conn in ipairs(conns) do
      local ok, err = M.send(conn, data, opcode)
      if ok then
        sent = sent + 1
      elseif not first_err then
        first_err = err
      end
    end
    return sent, first_err
  end,
}

return M
