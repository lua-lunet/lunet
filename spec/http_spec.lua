-- Behavioural suite for the pure-Lua HTTP extension trio:
--   lunet.http          (ext/http/http.lua)          framing + responses + CORS
--   lunet.http_context  (ext/http/http_context.lua)  per-request context
--   lunet.http_router   (ext/http/router.lua)        method+path dispatch
--
-- Module resolution mirrors spec/jsonic_spec.lua: the loaders are Lua
-- files under ext/, not C modules; package.preload routes
-- require("lunet.http*") to the dev-tree files explicitly. lunet.jsonic
-- is preloaded the same way because the router's JSON contract and the
-- JSON response helpers need its encoder (the dkjson encode half is
-- pure Lua; the native decoder is never exercised here).

describe("http extension modules", function()
  local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"

  package.preload["lunet.jsonic"] = function()
    return assert(loadfile(spec_dir .. "/../ext/jsonic/jsonic.lua"))()
  end
  package.preload["lunet.http"] = function()
    return assert(loadfile(spec_dir .. "/../ext/http/http.lua"))()
  end
  package.preload["lunet.http_context"] = function()
    return assert(loadfile(spec_dir .. "/../ext/http/http_context.lua"))()
  end
  package.preload["lunet.http_router"] = function()
    return assert(loadfile(spec_dir .. "/../ext/http/router.lua"))()
  end

  local ok, http = pcall(require, "lunet.http")
  if not ok then
    pending("lunet.http loader not found (ext/http/http.lua)", function() end)
    return
  end
  local http_context = require("lunet.http_context")
  local router = require("lunet.http_router")

  -- Parse a full raw request or fail the test with the parser's message.
  local function parse(raw)
    local request, err, status = http.parse_request(raw)
    assert(request, tostring(err) .. " (status " .. tostring(status) .. ")")
    return request
  end

  -- Build a fresh context for method/path, run it through the router
  -- and return the context for status/body/header assertions.
  local function drive(method, path, env_config, body)
    local ctx = http_context.new({
      method = method,
      path = path,
      headers = {},
      body = body or "",
      query_params = {},
      query_string = "",
    })
    ctx.env_config = env_config
    router.handle(ctx)
    return ctx
  end

  -- Same as drive(), but the context's stderr logging is silenced
  -- first: the 500 contract logs the swallowed error before returning.
  local function drive_silent(method, path, env_config, body)
    local ctx = http_context.new({
      method = method,
      path = path,
      headers = {},
      body = body or "",
      query_params = {},
      query_string = "",
    })
    ctx.env_config = env_config
    ctx.log = function() end
    router.handle(ctx)
    return ctx
  end

  describe("http.parse_request (framing)", function()
    it("parses the request line, headers and body", function()
      local r = parse("POST /a/b?x=1&tag=a%20b HTTP/1.1\r\nHost: h\r\n" ..
                      "Content-Length: 5\r\nX-Weird:  spaced  \r\n\r\nhello")
      assert.are.equal("POST", r.method)
      assert.are.equal("/a/b", r.path)
      assert.are.equal("HTTP/1.1", r.version)
      assert.are.equal("h", r.headers.host)
      assert.are.equal("spaced", r.headers["x-weird"])
      assert.are.equal("hello", r.body)
      assert.are.equal("x=1&tag=a%20b", r.query_string)
      assert.are.equal("1", r.query_params.x)
      assert.are.equal("a b", r.query_params.tag)
    end)

    it("defaults the body to the empty string", function()
      local r = parse("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
      assert.are.equal("", r.body)
    end)

    it("rejects a body shorter than Content-Length", function()
      local request, err, status = http.parse_request(
        "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhi")
      assert.is_nil(request)
      assert.are.equal("Incomplete request body", err)
      assert.are.equal(400, status)
    end)

    it("rejects extra data after the declared body", function()
      local request, err, status = http.parse_request(
        "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi!extra")
      assert.is_nil(request)
      assert.are.equal("Unexpected data after request body", err)
      assert.are.equal(400, status)
    end)

    it("requires a Host header", function()
      local request, err, status = http.parse_request("GET / HTTP/1.1\r\n\r\n")
      assert.is_nil(request)
      assert.are.equal("Missing Host header", err)
      assert.are.equal(400, status)
    end)

    it("rejects Transfer-Encoding (no chunked support)", function()
      local request, err = http.parse_request(
        "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n")
      assert.is_nil(request)
      assert.are.equal("Transfer-Encoding is not supported", err)
    end)

    it("rejects duplicate headers", function()
      local request, err = http.parse_request(
        "GET / HTTP/1.1\r\nHost: h\r\nHost: again\r\n\r\n")
      assert.is_nil(request)
      assert.are.equal("Duplicate HTTP header", err)
    end)

    it("rejects non-HTTP/1.1 versions with 505", function()
      local request, err, status = http.parse_request("GET / HTTP/1.0\r\nHost: h\r\n\r\n")
      assert.is_nil(request)
      assert.are.equal("Only HTTP/1.1 is supported", err)
      assert.are.equal(505, status)
    end)

    it("rejects a non-numeric Content-Length", function()
      local request, err, status = http.parse_request(
        "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 4x\r\n\r\n")
      assert.is_nil(request)
      assert.are.equal("Invalid Content-Length", err)
      assert.are.equal(400, status)
    end)

    it("rejects bodies over MAX_BODY_BYTES with 413", function()
      local request, err, status = http.parse_request(
        "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: " ..
        (http.MAX_BODY_BYTES + 1) .. "\r\n\r\n")
      assert.is_nil(request)
      assert.are.equal("Request body too large", err)
      assert.are.equal(413, status)
    end)

    it("rejects headers over MAX_HEADER_BYTES with 431", function()
      local request, err, status = http.parse_request("GET / HTTP/1.1\r\nHost: h\r\n" ..
        string.rep("x", http.MAX_HEADER_BYTES))
      assert.is_nil(request)
      assert.are.equal("Request headers too large", err)
      assert.are.equal(431, status)
    end)

    it("rejects a non-string argument", function()
      local request, err = http.parse_request(nil)
      assert.is_nil(request)
      assert.are.equal("Invalid HTTP request", err)
    end)
  end)

  describe("http.read_request (incremental framing)", function()
    local RAW = "POST /kv/hits HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\n0123456789"

    local function feed(...)
      local chunks = { ... }
      local index = 0
      return function()
        index = index + 1
        return chunks[index]
      end
    end

    local function feed_err(err)
      return function()
        return nil, err
      end
    end

    it("assembles a request split across arbitrary chunks", function()
      local r = assert(http.read_request(feed("POST /kv/hits HT", "TP/1.1\r\nHost: h\r\n",
                                              "Content-Length: 10\r\n\r\n", "0123", "456789")))
      assert.are.equal("POST", r.method)
      assert.are.equal("/kv/hits", r.path)
      assert.are.equal("0123456789", r.body)
      assert.are.equal(RAW, r.raw)
    end)

    it("stops at the end of the declared body without reading further chunks", function()
      local consumed = false
      local chunks = { "POST /kv/hits HTTP/1.1\r\nHost: h\r\n" ..
                       "Content-Length: 2\r\n\r\nhi", "!extra" }
      local r = assert(http.read_request(function()
        if not chunks[1] then
          consumed = true
          return chunks[2]
        end
        local c = chunks[1]
        chunks[1] = nil
        return c
      end))
      assert.is_truthy(r)
      assert.are.equal("hi", r.body)
      assert.is_false(consumed)
    end)

    it("returns no error when plain EOF hits before any bytes", function()
      local r, err = http.read_request(feed())
      assert.is_nil(r)
      assert.is_nil(err)
    end)

    it("passes a reader error through when EOF hits before any bytes", function()
      local r, err = http.read_request(feed_err("closed"))
      assert.is_nil(r)
      assert.are.equal("closed", err)
    end)

    it("reports an incomplete request when EOF hits mid-body", function()
      local r, err, status = http.read_request(feed(
        "POST /kv/hits HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\n012"))
      assert.is_nil(r)
      assert.are.equal("Incomplete HTTP request", err)
      assert.are.equal(400, status)
    end)

    it("rejects data past the declared body within the received bytes", function()
      local r, err = http.read_request(feed(
        "POST /kv/hits HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi!extra"))
      assert.is_nil(r)
      assert.are.equal("Unexpected data after request body", err)
    end)
  end)

  describe("http.response (framing)", function()
    it("writes the Content-Length from the body bytes", function()
      local resp = http.response(200, {}, "hello")
      assert.are.truthy(resp:find("Content%-Length: 5\r\n", 1, false))
      assert.are.truthy(resp:find("\r\n\r\nhello$", 1, false))
    end)

    it("drops a caller-supplied Connection header in both modes", function()
      local persistent_resp = http.response(200, { Connection = "close" }, "")
      assert.is_nil(persistent_resp:find("connection:", 1, false))
      local closing = http.response(200, { Connection = "keep-alive" }, "", nil, false)
      assert.are.truthy(closing:find("connection: close", 1, false))
      assert.is_nil(closing:find("keep%-alive", 1, false))
    end)

    it("drops a caller-supplied Content-Length (framing is owned here)", function()
      local resp = http.response(200, { ["Content-Length"] = "999" }, "ab")
      assert.are.truthy(resp:find("Content%-Length: 2\r\n", 1, false))
      assert.is_nil(resp:find("999", 1, false))
    end)

    it("defaults Content-Type to application/json and lets the caller win", function()
      assert.are.truthy(http.response(200, {}, ""):find("content%-type: application/json", 1, false))
      assert.are.truthy(http.response(200, { ["Content-Type"] = "text/plain" }, "")
                          :find("content%-type: text/plain", 1, false))
    end)

    it("names known statuses and falls back to Unknown", function()
      assert.are.truthy(http.response(201, {}, ""):find("^HTTP/1.1 201 Created", 1, false))
      assert.are.truthy(http.response(404, {}, ""):find("^HTTP/1.1 404 Not Found", 1, false))
      assert.are.truthy(http.response(599, {}, ""):find("^HTTP/1.1 599 Unknown", 1, false))
    end)

    it("treats nil headers and body as empty", function()
      local resp = http.response(200, nil, nil)
      assert.are.truthy(resp:find("Content%-Length: 0\r\n\r\n$", 1, false))
    end)
  end)

  describe("http JSON responses", function()
    it("json_response encodes the payload and sets the status line", function()
      local resp = http.json_response(201, { ok = true })
      assert.are.truthy(resp:find("^HTTP/1.1 201 Created", 1, false))
      assert.are.truthy(resp:find('{"ok":true}', 1, true))
    end)

    it("error_response wraps the payload in the errors envelope", function()
      local resp = http.error_response(404, { "no such route" })
      assert.are.truthy(resp:find("^HTTP/1.1 404 Not Found", 1, false))
      assert.are.truthy(resp:find('{"errors":["no such route"]}', 1, true))
    end)
  end)

  describe("http CORS (opt-in, default off)", function()
    local cors = {
      origin = "https://app.example",
      methods = { "GET", "POST", "PATCH" },
      headers = { "Content-Type", "Authorization" },
      max_age = 600,
      credentials = true,
    }

    it("adds nothing when no cors config is given", function()
      assert.is_nil(http.response(200, {}, "x"):find("access%-control", 1, false))
      assert.is_nil(http.json_response(200, {}):find("access%-control", 1, false))
      assert.are.same({}, http.cors_headers(nil))
    end)

    it("builds the Access-Control header set from the config", function()
      local headers = http.cors_headers(cors)
      assert.are.equal("https://app.example", headers["access-control-allow-origin"])
      assert.are.equal("GET, POST, PATCH", headers["access-control-allow-methods"])
      assert.are.equal("Content-Type, Authorization", headers["access-control-allow-headers"])
      assert.are.equal("600", headers["access-control-max-age"])
      assert.are.equal("true", headers["access-control-allow-credentials"])
    end)

    it("accepts plain strings for methods and headers", function()
      local headers = http.cors_headers({ origin = "https://a.b", methods = "GET, POST" })
      assert.are.equal("GET, POST", headers["access-control-allow-methods"])
      assert.is_nil(headers["access-control-allow-headers"])
    end)

    it("carries the headers on normal responses when configured", function()
      local resp = http.response(200, {}, "x", cors)
      assert.are.truthy(resp:find("access%-control%-allow%-origin: https://app%.example", 1, false))
      assert.are.truthy(resp:find("access%-control%-allow%-methods: GET, POST, PATCH", 1, false))
      local jresp = http.json_response(200, { ok = 1 }, cors)
      assert.are.truthy(jresp:find("access%-control%-allow%-origin", 1, false))
    end)

    it("lets a caller-supplied header win over the CORS header", function()
      local resp = http.response(200,
        { ["Access-Control-Allow-Origin"] = "https://other.example" }, "x", cors)
      assert.are.truthy(resp:find("access%-control%-allow%-origin: https://other%.example", 1, false))
      assert.is_nil(resp:find("app%.example", 1, false))
    end)

    it("detects preflights: OPTIONS with Origin and Access-Control-Request-Method", function()
      local preflight = parse("OPTIONS /kv/hits HTTP/1.1\r\nHost: h\r\n" ..
        "Origin: https://app.example\r\nAccess-Control-Request-Method: PATCH\r\n\r\n")
      assert.is_true(http.is_preflight(preflight))

      local plain_options = parse("OPTIONS /kv/hits HTTP/1.1\r\nHost: h\r\n\r\n")
      assert.is_false(http.is_preflight(plain_options))

      local get = parse("GET /kv/hits HTTP/1.1\r\nHost: h\r\n" ..
        "Origin: https://app.example\r\nAccess-Control-Request-Method: PATCH\r\n\r\n")
      assert.is_false(http.is_preflight(get))
    end)

    it("short-circuits preflights with an empty CORS-carrying response", function()
      local resp = http.preflight_response(cors)
      assert.are.truthy(resp:find("^HTTP/1.1 200 OK", 1, false))
      assert.are.truthy(resp:find("access%-control%-allow%-origin: https://app%.example", 1, false))
      assert.are.truthy(resp:find("access%-control%-max%-age: 600", 1, false))
      assert.are.truthy(resp:find("Content%-Length: 0\r\n\r\n$", 1, false))
    end)

    it("preflight_response honours persistent=false", function()
      local closing = http.preflight_response(cors, false)
      assert.are.truthy(closing:find("connection: close", 1, false))
      assert.are.truthy(closing:find("access%-control%-allow%-origin", 1, false))
      local persistent = http.preflight_response(cors)
      assert.is_nil(persistent:find("connection:", 1, false))
    end)
  end)

  describe("http keep-alive framing (persistent connections)", function()
    it("is persistent by default: no Connection header, per HTTP/1.1", function()
      local resp = http.response(200, {}, "hello")
      assert.is_nil(resp:find("connection:", 1, false))
      assert.are.truthy(resp:find("Content%-Length: 5\r\n", 1, false))
    end)

    it("declares Connection: close when persistent is false", function()
      local resp = http.response(200, {}, "hello", nil, false)
      assert.are.truthy(resp:find("connection: close\r\n", 1, false))
    end)

    it("treats persistent=true like the default", function()
      local resp = http.response(200, {}, "", true)
      assert.is_nil(resp:find("connection:", 1, false))
    end)

    it("passes persistent through json_response and error_response", function()
      local jclose = http.json_response(200, { ok = true }, nil, false)
      assert.are.truthy(jclose:find("connection: close", 1, false))
      local jpersistent = http.json_response(200, { ok = true })
      assert.is_nil(jpersistent:find("connection:", 1, false))
      local eclose = http.error_response(404, { "gone" }, nil, false)
      assert.are.truthy(eclose:find("connection: close", 1, false))
      local epersistent = http.error_response(404, { "gone" })
      assert.is_nil(epersistent:find("connection:", 1, false))
    end)

    it("still rejects pipelined bytes past the body with a hard 400", function()
      local r, err, status = http.read_request(function()
        return "GET /kv/one HTTP/1.1\r\nHost: h\r\n\r\n" ..
               "GET /kv/two HTTP/1.1\r\nHost: h\r\n\r\n"
      end)
      assert.is_nil(r)
      assert.are.equal("Unexpected data after request body", err)
      assert.are.equal(400, status)
    end)

    -- The documented per-connection serve pattern (docs/HTTP.md,
    -- examples/08_http.lua): sequential requests on one connection until
    -- the client's EOF, a framing error, or a request-declared close.
    local function serve_connection(read_chunk, write_response)
      router.reset()
      router.route("GET", "/kv/:name", function(_, _, params)
        return { name = params.name }
      end)
      while true do
        local request, read_err, read_status = http.read_request(read_chunk)
        if not request and not read_status then
          return "eof"  -- idle/EOF close owns the exit
        end
        if not request then
          write_response(http.error_response(read_status or 400, { read_err }, nil, false))
          return "error"
        end
        local persistent = (request.headers["connection"] or ""):lower() ~= "close"
        local ctx = http_context.new(request)
        ctx.env_config = {}
        router.handle(ctx)
        write_response(http.response(ctx.status, ctx.res_headers,
                                     ctx.response_body(), nil, persistent))
        if not persistent then
          return "request-close"
        end
      end
    end

    it("serves sequential requests on one connection and honours a request-declared close", function()
      local wire = {
        "GET /kv/one HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET /kv/two HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
      }
      local responses = {}
      local outcome = serve_connection(function()
        local chunk = wire[1]
        wire[1] = wire[2]
        wire[2] = nil
        return chunk
      end, function(response) responses[#responses + 1] = response end)

      assert.are.equal("request-close", outcome)
      assert.are.equal(2, #responses)
      -- First response: persistent — no Connection header, loop stayed open.
      assert.are.truthy(responses[1]:find('{"name":"one"}', 1, true))
      assert.is_nil(responses[1]:find("connection:", 1, false))
      -- Second response: the request declared close, so the response does
      -- too, and the loop ended.
      assert.are.truthy(responses[2]:find('{"name":"two"}', 1, true))
      assert.are.truthy(responses[2]:find("connection: close", 1, false))
    end)

    it("keeps the connection open across requests until the client's EOF", function()
      local wire = { "GET /kv/one HTTP/1.1\r\nHost: h\r\n\r\n" }
      local responses = {}
      local outcome = serve_connection(function()
        local chunk = wire[1]
        wire[1] = nil
        return chunk  -- nil afterwards: clean EOF, no error
      end, function(response) responses[#responses + 1] = response end)

      assert.are.equal("eof", outcome)
      assert.are.equal(1, #responses)
      assert.is_nil(responses[1]:find("connection:", 1, false))
    end)

    it("answers a framing error with Connection: close and stops serving the stream", function()
      -- An incomplete body (EOF mid-body) desynchronises the stream: the
      -- 400 declares close and the loop never reads again.
      local responses = {}
      local reads = 0
      local outcome = serve_connection(function()
        reads = reads + 1
        if reads == 1 then
          return "POST /kv/one HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhi"
        end
        return nil
      end, function(response) responses[#responses + 1] = response end)

      assert.are.equal("error", outcome)
      assert.are.equal(1, #responses)
      assert.are.truthy(responses[1]:find("^HTTP/1.1 400 Bad Request", 1, false))
      assert.are.truthy(responses[1]:find("connection: close", 1, false))
    end)
  end)

  describe("http_context", function()
    it("exposes the request fields read-only and the response defaults", function()
      local ctx = http_context.new(parse(
        "GET /kv/hits?by=2 HTTP/1.1\r\nHost: h\r\nX-Auth: t\r\n\r\n"))
      assert.are.equal("GET", ctx.method)
      assert.are.equal("/kv/hits", ctx.path)
      assert.are.equal("2", ctx.query.by)
      assert.are.equal("t", ctx.headers["x-auth"])
      assert.are.equal("", ctx.body)
      assert.are.equal(200, ctx.status)
      assert.are.same({}, ctx.res_headers)
      assert.are.equal("", ctx.response_body())
    end)

    it("accumulates write() chunks, coercing nil to the empty string", function()
      local ctx = http_context.new(parse("GET / HTTP/1.1\r\nHost: h\r\n\r\n"))
      ctx.write("a")
      ctx.write(nil)
      ctx.write("b")
      assert.are.equal("ab", ctx.response_body())
    end)

    it("keeps contexts isolated: one fresh table per request", function()
      local ctx_a = http_context.new(parse("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"))
      local ctx_b = http_context.new(parse("GET /b HTTP/1.1\r\nHost: h\r\n\r\n"))
      ctx_a.status = 418
      ctx_a.write("x")
      assert.are.equal(200, ctx_b.status)
      assert.are.equal("", ctx_b.response_body())
    end)

    it("validates log levels and logs to stderr", function()
      local ctx = http_context.new(parse("GET / HTTP/1.1\r\nHost: h\r\n\r\n"))
      assert.has_no_error(function() ctx.log("err", "x", 1, nil) end)
      assert.has_error(function() ctx.log("loud", "nope") end)
    end)
  end)

  describe("http_router", function()
    before_each(function()
      router.reset()
    end)

    it("matches exact paths and captures :params", function()
      router.route("GET", "/kv/:name", function() return {} end)
      router.route("GET", "/users/:id/posts/:post_id", function() return {} end)

      local route, params = router.match("GET", "/kv/hits")
      assert.is_truthy(route)
      assert.are.equal("hits", params.name)

      local deep_route, deep = router.match("GET", "/users/42/posts/7")
      assert.is_truthy(deep_route)
      assert.are.equal("42", deep.id)
      assert.are.equal("7", deep.post_id)
    end)

    it("compares methods case-insensitively", function()
      router.route("get", "/kv/:name", function() return {} end)
      assert.is_truthy(router.match("GET", "/kv/hits"))
      assert.is_truthy(router.match("get", "/kv/hits"))
    end)

    it("does not match a supported path with an unsupported method", function()
      router.route("GET", "/kv/:name", function() return {} end)
      assert.is_nil(router.match("DELETE", "/kv/hits"))
    end)

    it("requires a handler function", function()
      assert.has_error(function() router.route("GET", "/x", nil) end)
    end)

    it("requires a middleware function", function()
      assert.has_error(function() router.use(nil) end)
    end)

    it("dispatches a table result as JSON with status 200", function()
      router.route("GET", "/kv/:name", function(config, _, params)
        return { name = params.name, value = config.store[params.name] or 0 }
      end)
      local ctx = drive("GET", "/kv/hits", { store = { hits = 7 } })
      assert.are.equal(200, ctx.status)
      assert.are.equal("application/json", ctx.res_headers["Content-Type"])
      local body = ctx.response_body()
      assert.are.truthy(body:find('"name":"hits"', 1, true))
      assert.are.truthy(body:find('"value":7', 1, true))
    end)

    it("unwraps a { status, body } result", function()
      router.route("POST", "/kv/:name", function()
        return { status = 201, body = { created = true } }
      end)
      local ctx = drive("POST", "/kv/hits", {})
      assert.are.equal(201, ctx.status)
      assert.are.truthy(ctx.response_body():find('"created":true', 1, true))
    end)

    it("writes a string result raw", function()
      router.route("GET", "/raw", function()
        return '{"raw":true}'
      end)
      local ctx = drive("GET", "/raw", {})
      assert.are.equal(200, ctx.status)
      assert.are.equal('{"raw":true}', ctx.response_body())
    end)

    it("lets a handler that returns nothing drive ctx directly", function()
      router.route("GET", "/manual", function(_, ctx)
        ctx.status = 202
        ctx.write("hand-made")
      end)
      local ctx = drive("GET", "/manual", {})
      assert.are.equal(202, ctx.status)
      assert.are.equal("hand-made", ctx.response_body())
    end)

    it("writes an empty body for 204", function()
      router.route("DELETE", "/kv/:name", function()
        return { status = 204, body = "ignored" }
      end)
      local ctx = drive("DELETE", "/kv/hits", {})
      assert.are.equal(204, ctx.status)
      assert.are.equal("", ctx.response_body())
    end)

    it("answers an unknown path with the 404 JSON contract", function()
      local ctx = drive("GET", "/nope", {})
      assert.are.equal(404, ctx.status)
      local body = ctx.response_body()
      assert.are.truthy(body:find('"error":"Not found"', 1, true))
      assert.are.truthy(body:find('"path":"/nope"', 1, true))
    end)

    it("answers a method mismatch with 404 (same as an unknown path)", function()
      router.route("GET", "/kv/:name", function() return {} end)
      local ctx = drive("DELETE", "/kv/hits", {})
      assert.are.equal(404, ctx.status)
    end)

    it("turns a handler error into the 500 JSON contract", function()
      router.route("GET", "/boom", function() error("kaboom") end)
      local ctx = drive_silent("GET", "/boom", {})
      assert.are.equal(500, ctx.status)
      assert.are.equal('{"error":"Internal server error"}', ctx.response_body())
    end)

    it("turns a JSON-encode failure into the 500 JSON contract", function()
      router.route("GET", "/unencodable", function()
        return { fn = print } -- functions have no JSON representation
      end)
      local ctx = drive_silent("GET", "/unencodable", {})
      assert.are.equal(500, ctx.status)
      assert.are.equal('{"error":"Internal server error"}', ctx.response_body())
    end)

    it("registers routes as a side effect of requiring a route module", function()
      package.preload["spec.fixture_routes"] = function()
        local r = require("lunet.http_router")
        r.route("GET", "/fixture/only", function() return { fixture = true } end)
        return r
      end
      require("spec.fixture_routes")

      local route = router.match("GET", "/fixture/only")
      assert.is_truthy(route)
      local ctx = drive("GET", "/fixture/only", {})
      assert.are.equal(200, ctx.status)
      assert.are.truthy(ctx.response_body():find('"fixture":true', 1, true))
    end)

    it("runs middleware in registration order, before dispatch", function()
      local order = {}
      router.use(function() order[#order + 1] = "first" end)
      router.use(function() order[#order + 1] = "second" end)
      router.use(function() order[#order + 1] = "third" end)
      router.route("GET", "/kv/:name", function()
        order[#order + 1] = "handler"
        return {}
      end)

      drive("GET", "/kv/hits", {})
      assert.are.same({ "first", "second", "third", "handler" }, order)
    end)

    it("lets middleware see and mutate the context before dispatch", function()
      router.use(function(ctx)
        ctx.res_headers["X-Middleware"] = "ran"
      end)
      router.route("GET", "/kv/:name", function() return {} end)

      local ctx = drive("GET", "/kv/hits", {})
      assert.are.equal("ran", ctx.res_headers["X-Middleware"])
    end)

    it("lets middleware short-circuit with a response value", function()
      local calls = {}
      router.use(function() calls[#calls + 1] = "m1" end)
      router.use(function(_)
        calls[#calls + 1] = "m2"
        return { status = 403, body = { error = "locked" } }
      end)
      router.use(function() calls[#calls + 1] = "m3-should-not-run" end)
      router.route("GET", "/kv/:name", function()
        calls[#calls + 1] = "handler-should-not-run"
        return {}
      end)

      local ctx = drive("GET", "/kv/hits", {})
      assert.are.same({ "m1", "m2" }, calls)
      assert.are.equal(403, ctx.status)
      assert.are.truthy(ctx.response_body():find('"error":"locked"', 1, true))
    end)

    it("short-circuits with a raw string body when a middleware returns one", function()
      router.use(function()
        return "blocked"
      end)
      router.route("GET", "/kv/:name", function() return {} end)

      local ctx = drive("GET", "/kv/hits", {})
      assert.are.equal(200, ctx.status)
      assert.are.equal("blocked", ctx.response_body())
      assert.are.equal("application/json", ctx.res_headers["Content-Type"])
    end)

    it("continues past middleware that returns nil or false", function()
      local calls = {}
      router.use(function() return nil end)
      router.use(function() return false end)
      router.route("GET", "/kv/:name", function()
        calls[#calls + 1] = "handler"
        return { reached = true }
      end)

      local ctx = drive("GET", "/kv/hits", {})
      assert.are.equal(1, #calls)
      assert.are.truthy(ctx.response_body():find('"reached":true', 1, true))
    end)

    it("turns a middleware error into the 500 JSON contract without dispatching", function()
      local dispatched = false
      router.use(function() error("middleware kaboom") end)
      router.route("GET", "/kv/:name", function()
        dispatched = true
        return {}
      end)

      local ctx = drive_silent("GET", "/kv/hits", {})
      assert.is_false(dispatched)
      assert.are.equal(500, ctx.status)
      assert.are.equal('{"error":"Internal server error"}', ctx.response_body())
    end)

    it("keeps handling requests after a failed one", function()
      router.route("GET", "/boom", function() error("kaboom") end)
      router.route("GET", "/kv/:name", function(config, _, params)
        return { value = config.store[params.name] or 0 }
      end)

      local failed = drive_silent("GET", "/boom", {})
      assert.are.equal(500, failed.status)

      local good = drive("GET", "/kv/hits", { store = { hits = 1 } })
      assert.are.equal(200, good.status)
      assert.are.truthy(good.response_body():find('"value":1', 1, true))
    end)
  end)
end)
