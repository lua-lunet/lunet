-- The happy-path target for the Http11Probe rig (ext/http/Dockerfile.http).
-- GET / answers 200; POST /echo echoes the request body. Everything the
-- framing subset rejects is answered by the connection loop per its status map.
local lunet = require("lunet")
local socket = require("lunet.socket")
local http = require("lunet.http")
local http_context = require("lunet.http_context")
local router = require("lunet.http_router")

router.route("GET", "/", function() return { server = "lunet", ok = true } end)
router.route("POST", "/echo", function(config, ctx)
  local body = ctx.body
  if body ~= "" then
    return { status = 200, body = body }
  end
  return { ok = true }
end)

local cors = nil

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
      ctx.env_config = {}
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

lunet.spawn(function()
  local listener = assert(socket.listen("tcp", "127.0.0.1", 8080),
                          "failed to listen on 127.0.0.1:8080")
  print("probe target listening on 127.0.0.1:8080")
  while true do
    local client = socket.accept(listener)
    if not client then break end
    lunet.spawn(function() handle_connection(client) end)
  end
end)

lunet.spawn(function()
  lunet.sleep(2147483647)
end)
