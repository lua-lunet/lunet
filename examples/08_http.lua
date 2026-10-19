-- HTTP demo: lnt_shared counters behind the router (middleware + CORS).
-- Routes:
--   GET   /counters/:name   read a counter (0 when never set)
--   POST  /counters/:name   increment by 1 (201)
--   PATCH /counters/:name   adjust by {"delta": <number>}
-- Run: xmake build-release && xmake build-lnt-shared && \
--      "$LUNET_BIN" examples/08_http.lua
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."

local json = require("lunet.jsonic")
local lnt = assert(loadfile(script_dir .. "/../ext/lnt_shared/lnt_shared.lua"))()
local lunet = require("lunet")
local socket = require("lunet.socket")
local http = require("lunet.http")
local http_context = require("lunet.http_context")
local router = require("lunet.http_router")

local counters = lnt.store("http_demo_counters", 1024 * 1024)
counters:flush_all()

router.use(function(ctx)
  print(string.format("[middleware] %s %s", ctx.method, ctx.path))
end)

router.use(function(ctx)
  if ctx.method == "PATCH" and ctx.path == "/counters/locked" then
    return { status = 403, body = { error = "counter is locked" } }
  end
end)

router.route("GET", "/counters/:name", function(config, _, params)
  local value = config.counters:get(params.name)
  return { name = params.name, value = value or 0 }
end)

router.route("POST", "/counters/:name", function(config, _, params)
  local value = config.counters:incr(params.name, 1, 0)
  return { status = 201, body = { name = params.name, value = value } }
end)

router.route("PATCH", "/counters/:name", function(config, ctx, params)
  local delta = 1
  if ctx.body ~= "" then
    local decoded = json.decode(ctx.body)
    if type(decoded) ~= "table" or type(decoded.delta) ~= "number" then
      return { status = 400,
               body = { errors = { "invalid JSON body: expected {\"delta\": <number>}" } } }
    end
    delta = decoded.delta
  end
  local value = config.counters:incr(params.name, delta, 0)
  return { name = params.name, delta = delta, value = value }
end)

local cors = {
  origin = "http://localhost:5173",
  methods = { "GET", "POST", "PATCH" },
  headers = { "Content-Type" },
}

local function handle_connection(client)
  while true do
    local request, read_err, read_status = http.read_request(function()
      local data, data_err = socket.read(client)
      if not data then return nil, data_err end
      return data
    end)
    if not request and not read_status then
      socket.close(client)
      return
    end
    if not request then
      socket.write(client, http.error_response(read_status or 400, { read_err }, nil, false))
      socket.close(client)
      return
    end

    local persistent = (request.headers["connection"] or ""):lower() ~= "close"
    if http.is_preflight(request) then
      socket.write(client, http.preflight_response(cors, persistent))
    else
      local ctx = http_context.new(request)
      ctx.env_config = { counters = counters }
      router.handle(ctx)
      socket.write(client, http.response(ctx.status, ctx.res_headers,
                                         ctx.response_body(), cors, persistent))
    end
    if not persistent then
      socket.close(client)
      return
    end
  end
end

local function http_request(method, path, body, extra_headers, keep_alive)
  body = body or ""
  return method .. " " .. path .. " HTTP/1.1\r\n" ..
         "Host: lunet-demo\r\n" ..
         (extra_headers or "") ..
         (body ~= "" and "Content-Type: application/json\r\n" or "") ..
         (keep_alive and "" or "Connection: close\r\n") ..
         "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

local function read_all(client)
  local parts = {}
  while true do
    local data = socket.read(client)
    if not data then break end
    parts[#parts + 1] = data
  end
  return table.concat(parts)
end

local function read_response(client)
  local received = ""
  while not received:find("\r\n\r\n", 1, true) do
    local buf = socket.read(client)
    if not buf then return nil, "connection closed before response head" end
    received = received .. buf
  end
  local head_end = received:find("\r\n\r\n", 1, true)
  local head = received:sub(1, head_end + 3)
  local body = received:sub(head_end + 4)
  local length = tonumber(head:match("Content%-Length: (%d+)")) or 0
  while #body < length do
    local buf = socket.read(client)
    if not buf then break end
    body = body .. buf
  end
  return head .. body
end

local function request(label, raw)
  local client = socket.connect("127.0.0.1", 18082)
  socket.write(client, raw)
  local response = read_all(client)
  socket.close(client)
  local status_line = response:match("^([^\r\n]+)")
  local resp_body = response:match("\r\n\r\n(.*)$")
  local cors_origin = response:match("access%-control%-allow%-origin: ([^\r\n]+)")
  print("-- " .. label)
  print("   " .. tostring(status_line) ..
        (cors_origin and ("  (Access-Control-Allow-Origin: " .. cors_origin .. ")") or ""))
  print("   " .. tostring(resp_body))
end

lunet.spawn(function()
  local listener, listen_err = socket.listen("tcp", "127.0.0.1", 18082)
  if not listener then
    print("Failed to listen: " .. (listen_err or "unknown"))
    return
  end
  print("=== lunet.http Demo — counters behind an HTTP router ===")
  print("listening on http://127.0.0.1:18082 (loopback only)")
  while true do
    local client, accept_err = socket.accept(listener)
    if not client then
      if accept_err then print("accept stopped: " .. accept_err) end
      break
    end
    lunet.spawn(function() handle_connection(client) end)
  end
end)

lunet.spawn(function()
  lunet.sleep(100)

  request("CORS preflight (short-circuits before dispatch)",
          http_request("OPTIONS", "/counters/hits", "",
                       "Origin: http://localhost:5173\r\nAccess-Control-Request-Method: PATCH\r\n"))
  request("GET a fresh counter", http_request("GET", "/counters/hits"))

  local keep_client = socket.connect("127.0.0.1", 18082)
  socket.write(keep_client, http_request("GET", "/counters/keepalive", nil, nil, true))
  local first = assert(read_response(keep_client))
  socket.write(keep_client, http_request("POST", "/counters/keepalive", nil, nil, true))
  local second = assert(read_response(keep_client))
  socket.close(keep_client)
  print("-- two requests, one connection (keep-alive)")
  print("   " .. tostring(first:match("^([^\r\n]+)")) .. "  " ..
        tostring(first:match("\r\n\r\n(.*)$")))
  print("   " .. tostring(second:match("^([^\r\n]+)")) .. "  " ..
        tostring(second:match("\r\n\r\n(.*)$")))

  request("POST increments (1)", http_request("POST", "/counters/hits"))
  request("POST increments (2)", http_request("POST", "/counters/hits"))
  request("POST increments (3)", http_request("POST", "/counters/hits"))
  request("PATCH adjusts by a JSON delta",
          http_request("PATCH", "/counters/hits", '{"delta":10}'))
  request("PATCH the locked counter (middleware short-circuits with 403)",
          http_request("PATCH", "/counters/locked", '{"delta":1}'))
  request("PATCH with a bad body (400)", http_request("PATCH", "/counters/hits", "not-json"))
  request("GET an unknown route (404)", http_request("GET", "/nope"))

  print()
  print("=== Demo complete ===")
  __lunet_exit_code = 0
  lunet.stop()
end)
