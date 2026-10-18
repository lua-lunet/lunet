--[[
HTTP Router Demo for lunet — lnt_shared counters behind an HTTP API

CONTRIVED on purpose: the counters are a toy key-value store standing in
for whatever your handlers would read and write (a database, files, ...).
The point of the demo is the wiring — lunet.http (request framing and
responses), lunet.http_context (per-request state), lunet.http_router
(routes + middleware) and lunet.lnt_shared (shared counters) — in one
runnable file:

  - GET   /counters/:name   reads a counter (0 when never set)
  - POST  /counters/:name   increments it by 1 (201 Created)
  - PATCH /counters/:name   adjusts it by {"delta": <number>} from the body

Two restored conventions are shown along the way:
  - middleware: a logging hook plus a guard that short-circuits
    PATCH /counters/locked with 403 before dispatch
  - opt-in CORS: a preflight OPTIONS is answered with the configured
    Access-Control headers, and every response carries them

Connections are persistent by default (HTTP/1.1): the server serves
sequential requests on one connection until the client's EOF, a framing
error, or a request-declared Connection: close. The demo driver sends
one keep-alive exchange (two requests, one connection) and closes every
other connection by declaring Connection: close on its requests.

Prerequisites
  1. Build the runtime (copies the ext/http Lua modules beside lunet-run):
        xmake build-release
  2. Build the lnt_shared Rust extension once:
        xmake build-lnt-shared

  3. Run this example:
        "$LUNET_BIN" examples/08_http.lua
]]

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."

-- lunet.jsonic is needed by the router's JSON contract and the PATCH
-- body decode. It resolves natively in release archives; from a source
-- tree, fall back to the extension directory beside this script. The
-- decoder's FFI library is also warmed up here, before the event loop
-- starts: loading it lazily on the first decode can fork() while the
-- loop's worker threads are live, which occasionally deadlocks.
local ok_jsonic, json = pcall(require, "lunet.jsonic")
if not ok_jsonic then
  local jsonic_chunk, jsonic_err = loadfile(script_dir .. "/../ext/jsonic/jsonic.lua")
  if not jsonic_chunk then
    error("Cannot find jsonic.lua: " .. tostring(jsonic_err))
  end
  package.preload["lunet.jsonic"] = function() return jsonic_chunk() end
  json = require("lunet.jsonic")
end
json.decode("{}")  -- warm-up: load the native decoder before any socket work

-- Load the lnt_shared Lua wrapper from the extension directory.
local ext_lua = script_dir .. "/../ext/lnt_shared/lnt_shared.lua"
local chunk, err = loadfile(ext_lua)
if not chunk then
  error("Cannot find lnt_shared.lua: " .. tostring(err) ..
        "\nBuild with: cd ext/lnt_shared && cargo build --release")
end
local lnt = chunk()

local lunet = require("lunet")
local socket = require("lunet.socket")
local http = require("lunet.http")
local http_context = require("lunet.http_context")
local router = require("lunet.http_router")

-- ── The contrived kv store ────────────────────────────────────────────────
local counters = lnt.store("http_demo_counters", 1024 * 1024)
counters:flush_all()  -- deterministic demo output

-- ── Middleware (before dispatch, in registration order) ───────────────────
router.use(function(ctx)
  print(string.format("[middleware] %s %s", ctx.method, ctx.path))
end)

router.use(function(ctx)
  -- A middleware may short-circuit by returning a response value:
  if ctx.method == "PATCH" and ctx.path == "/counters/locked" then
    return { status = 403, body = { error = "counter is locked" } }
  end
end)

-- ── Routes (a method switch over the counters) ────────────────────────────
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

-- ── Opt-in CORS (default off: without this table nothing is added) ────────
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
      -- EOF before any bytes: a closed or idle client owns the close.
      socket.close(client)
      return
    end
    if not request then
      -- A framing error desynchronises the stream: declare close, stop.
      socket.write(client, http.error_response(read_status or 400, { read_err }, nil, false))
      socket.close(client)
      return
    end

    -- A request-declared Connection: close is honoured: the response
    -- declares close too, and the loop ends after writing it.
    local persistent = (request.headers["connection"] or ""):lower() ~= "close"
    if http.is_preflight(request) then
      -- CORS preflight short-circuit: never dispatched to the router.
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

-- ── A tiny raw-socket client so the demo drives itself ────────────────────
-- Every driver request declares Connection: close unless overridden, so
-- the server answers, closes, and read_all() sees an EOF.
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

-- Read exactly one response by framing (head + Content-Length body):
-- a persistent response has no EOF to read to.
local function read_response(client)
  local received = ""
  while not received:find("\r\n\r\n", 1, true) do
    local chunk = socket.read(client)
    if not chunk then return nil, "connection closed before response head" end
    received = received .. chunk
  end
  local head_end = received:find("\r\n\r\n", 1, true)
  local head = received:sub(1, head_end + 3)
  local body = received:sub(head_end + 4)
  local length = tonumber(head:match("Content%-Length: (%d+)")) or 0
  while #body < length do
    local chunk = socket.read(client)
    if not chunk then break end
    body = body .. chunk
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
  print("=== lunet.http Demo — counters behind an HTTP router (contrived) ===")
  print("listening on http://127.0.0.1:18082 (loopback only)")
  while true do
    local client, accept_err = socket.accept(listener)
    if not client then
      -- The listener is closed or closing (a deliberate lunet.stop()
      -- drains the loop and wakes this coroutine with an error).
      if accept_err then print("accept stopped: " .. accept_err) end
      break
    end
    lunet.spawn(function() handle_connection(client) end)
  end
end)

lunet.spawn(function()
  lunet.sleep(100)  -- let the listener come up first

  request("CORS preflight (short-circuits before dispatch)",
          http_request("OPTIONS", "/counters/hits", "",
                       "Origin: http://localhost:5173\r\nAccess-Control-Request-Method: PATCH\r\n"))
  request("GET a fresh counter", http_request("GET", "/counters/hits"))

  -- Two requests, one connection: neither declares Connection: close, so
  -- the server serves them sequentially (persistent by default).
  local keep_client = socket.connect("127.0.0.1", 18082)
  socket.write(keep_client, http_request("GET", "/counters/keepalive", nil, nil, true))
  local first = read_response(keep_client)
  socket.write(keep_client, http_request("POST", "/counters/keepalive", nil, nil, true))
  local second = read_response(keep_client)
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
  -- Deliberate-stop exit-code convention: without an explicit code the
  -- runtime reports uv_run's own result, which is nonzero after a stop
  -- that drained live handles.
  __lunet_exit_code = 0
  lunet.stop()
end)
