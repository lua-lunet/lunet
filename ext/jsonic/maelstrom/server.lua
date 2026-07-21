--[[
  Maelstrom node server for the lunet.jsonic demo.

  Listens on 127.0.0.1:18090 (loopback only, per repo security rules) and
  serves a minimal HTTP/1.1 API:

    GET  /health  -> 200 "ok"              (readiness probe for the rig)
    POST /msg     -> one Maelstrom JSON-RPC message per request body

  Supported Maelstrom message types:
    init -> init_ok
    echo -> echo_ok
    anything else -> {"type":"error","code":10,...}

  Run locally:
    LUNET_JSONIC_LIB=ext/jsonic/target/release/liblunet_jsonic.dylib \
      ./build/macosx/arm64/release/lunet-run ext/jsonic/maelstrom/server.lua
]]

local lunet = require("lunet")
local socket = require("lunet.socket")

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local chunk, load_err = loadfile(script_dir .. "/../jsonic.lua")
assert(chunk, "cannot load jsonic.lua: " .. tostring(load_err))
local json = chunk()

local HOST = "127.0.0.1"
local PORT = tonumber(os.getenv("MAELSTROM_PORT") or "18090")

local next_msg_id = 0
local function next_id()
  next_msg_id = next_msg_id + 1
  return next_msg_id
end

-- Maelstrom JSON-RPC handling. Replies mirror the request with src/dest
-- swapped; body.msg_id values are server-allocated and monotonic.
local function handle_message(raw)
  local msg, _, decode_err = json.decode(raw)
  if not msg or type(msg) ~= "table" or type(msg.body) ~= "table" then
    return json.encode({
      src = "n1",
      dest = "c1",
      body = { type = "error", code = 12, text = "invalid request: " .. tostring(decode_err) },
    })
  end

  local body = msg.body
  local reply_body
  if body.type == "init" then
    reply_body = { type = "init_ok", msg_id = next_id(), in_reply_to = body.msg_id }
  elseif body.type == "echo" then
    reply_body = {
      type = "echo_ok",
      msg_id = next_id(),
      in_reply_to = body.msg_id,
      echo = body.echo,
    }
  else
    reply_body = {
      type = "error",
      msg_id = next_id(),
      in_reply_to = body.msg_id,
      code = 10,
      text = "unsupported request type: " .. tostring(body.type),
    }
  end

  return json.encode({ src = msg.dest, dest = msg.src, body = reply_body })
end

-- Reads one full HTTP request (headers + Content-Length body) from a client.
local function read_request(client)
  local data = ""
  while true do
    local chunk_data, err = socket.read(client)
    if not chunk_data then
      return nil, err
    end
    data = data .. chunk_data
    local header_end = data:find("\r\n\r\n", 1, true)
    if header_end then
      local headers = data:sub(1, header_end - 1)
      local method, path = headers:match("^(%w+)%s+([^%s]+)")
      local clen = tonumber(headers:match("Content%-Length:%s*(%d+)") or "0")
      local body_start = header_end + 4
      if #data - body_start + 1 >= clen then
        return {
          method = method,
          path = path,
          body = data:sub(body_start, body_start + clen - 1),
        }
      end
    end
  end
end

local function respond(client, status, body, content_type)
  local response = "HTTP/1.1 " .. status .. "\r\n" ..
    "Content-Type: " .. content_type .. "\r\n" ..
    "Content-Length: " .. #body .. "\r\n" ..
    "Connection: close\r\n\r\n" .. body
  socket.write(client, response)
  socket.close(client)
end

local function handle_client(client)
  local req = read_request(client)
  if not req then
    socket.close(client)
    return
  end
  if req.method == "GET" and req.path == "/health" then
    respond(client, "200 OK", "ok", "text/plain")
  elseif req.method == "POST" and req.path == "/msg" then
    local ok, reply = pcall(handle_message, req.body)
    if ok then
      respond(client, "200 OK", reply, "application/json")
    else
      respond(client, "500 Internal Server Error", tostring(reply), "text/plain")
    end
  else
    respond(client, "404 Not Found", "not found", "text/plain")
  end
end

lunet.spawn(function()
  local listener, lerr = socket.listen("tcp", HOST, PORT)
  if not listener then
    io.stderr:write("server: listen failed: " .. tostring(lerr) .. "\n")
    return
  end
  io.stderr:write("server: maelstrom node listening on http://" .. HOST .. ":" .. PORT .. "\n")
  while true do
    local client = socket.accept(listener)
    if client then
      lunet.spawn(function()
        handle_client(client)
      end)
    end
  end
end)
