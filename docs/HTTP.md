# lunet.http / lunet.http_context / lunet.http_router

A pure-Lua HTTP/1.1 trio for building small servers on `lunet.socket`:

- [`lunet.http`](#lunethttp--request-framing-and-responses) - request parsing, response building, opt-in CORS
- [`lunet.http_context`](#lunethttpcontext--per-request-context) - one fresh per-request context object
- [`lunet.http_router`](#lunethttprouter--routes-and-middleware) - method+path dispatch with `:params` and middleware

The modules are plain Lua files, no C core and no new dependency: they ship
in the release archives (see [docs/RELEASE-LAYOUT.md](RELEASE-LAYOUT.md) for
the archive map), and `xmake build-release` copies them next to `lunet-run`
from a source tree, where the runtime's `lunet/?.lua` path entry resolves
them. The socket I/O (listen, accept, read, write, close) stays with the
caller; the JSON helpers require `lunet.jsonic` lazily, only when called.

A runnable end-to-end demo lives at [`examples/08_http.lua`](../examples/08_http.lua).

## The framing subset

Deployment security first: the qmail-style model in
[docs/SECURITY_ARCHITECTURE.md](SECURITY_ARCHITECTURE.md) - a battle-hardened
nginx (or similar) terminates the network interface and talks to your lunet
process over the loopback interface, or over a Unix domain socket if you
prefer filesystem permissions to IP rules. This module's server example binds
loopback only; it is not a TLS terminator and never should be.

The framing this module implements is a deliberately small subset of
HTTP/1.1:

The parser deliberately supports a small, explicit HTTP/1 subset:

- origin-form requests, CRLF header lines; one connection serves requests
  sequentially, one after another, until the connection closes; requests
  already buffered on the wire are served too (pipelining, below)
- at most one value per header field, optional decimal `Content-Length`
  body
- `Transfer-Encoding: chunked` is accepted (case-insensitive, alone and
  final) and the body is decoded before the request is served; any other
  transfer coding is rejected with 501
- HTTP/1.0 requests with a `Host` header are accepted and served with
  `Connection: close`; a missing `Host` is a 400 on every version, and
  HTTP/0.9 (no version at all) is a 400
- connections are persistent by default (HTTP/1.1): responses carry no
  `Connection` header. Pass `persistent=false` as the last argument of
  `http.response`/`http.json_response`/`http.error_response` (and
  `http.preflight_response`) for a `Connection: close` response.
- a request declaring `Connection: close` is honoured: build its response
  with `persistent=false` and end the connection loop after writing it.
  HTTP/1.0 requests carry `request.persistent_connection = false`; build
  their response the same way and close
- to serve the requests buffered on the wire, wrap the connection's
  chunk reader with `http.new_connection` and call `next_request()` per
  request: the bytes a request does not consume are the next request's
  input. The one-shot `http.read_request` keeps the older strict
  contract: bytes past the declared body are a hard 400
- `MAX_HEADER_BYTES` (16 KiB), `MAX_BODY_BYTES` (1 MiB) and
  `MAX_REQUEST_LINE_BYTES` (8 KiB) guard the parser
- rejections carry the RFC 9112 status: grammar and Host violations
  answer 400, a non-1.x major version answers 505, an unsupported
  transfer coding answers 501, a request line past its cap answers 414,
  headers past their cap answer 431, a body past its cap answers 413,
  and the router answers 405 with an Allow header when only the method
  is wrong

Parse failures follow the `nil, message, status` convention, so a connection
loop can answer `http.error_response(status, { message })` directly.

This class is probed, not just spec'd: the [Http11Probe](https://github.com/uNetworkingAB/Http11Probe)
rig (`ext/http/Dockerfile.http`) runs the probe's 213-case matrix against the
happy-path target in this folder and asserts the outcome. Out-of-scope tests
pass because the subset rejects the feature by design - non-chunked
`Transfer-Encoding` answers 501, `OPTIONS *` answers 400, and the minimal
echo target answers 405 with an `Allow` header for un-routed methods.
Rerun and commit the regenerated expectation manifest when `ext/http` code
changes:

```sh
docker build -f ext/http/Dockerfile.http -t lunet-http-probe .
docker run --rm -v "$(pwd)/ext/http/spec:/out" lunet-http-probe
```

The mounted run (manifest mode) writes the run's artifacts into the mounted
folder: `probe-results.json` (the raw responses, the review record),
`probe-manifest.lua` (the expectation manifest generated inside the image:
one sha256 per http module file, the summary count, and one verdict/status
entry per probe test) and nothing else. `probe_allowlist.lua` sits beside
them: the by-design outcomes, one entry per manifest id whose verdict is not
`Pass`. The three are committed; `spec/http_probe_spec.lua` pins them, so a
run whose outcomes drift (a probe version bump, an ext change) fails the
suite unless the allowlist is updated with the run.

## lunet.http - request framing and responses

```lua
local http = require("lunet.http")
```

| Function | Returns | Notes |
|----------|---------|-------|
| `http.parse_request(raw)` | `request, err, status` | Parses one complete raw request (head + body). A `Content-Length` body must exactly match the declared length; a chunked body is decoded and the buffer must end at the last-chunk terminator. |
| `http.read_request(read_chunk)` | `request, err, status` | Incremental variant for one request: `read_chunk()` is called until the request is complete and must return a string chunk, or nil plus an optional error on EOF/failure. Bytes past the declared body are a hard 400. |
| `http.new_connection(read_chunk)` | `connection` | Wraps a connection's chunk reader for sequential serving: `connection:next_request()` returns `request, err, status` and keeps leftover bytes queued for serving the requests buffered on the wire (pipelining). One wrapper per open connection. |
| `http.response(status, headers, body, cors?, persistent?)` | `string` | Builds the full response. Framing is owned here: caller `Content-Length`/`Connection` headers are dropped and replaced (`Content-Length` from the body). The connection is persistent by default - no `Connection` header, per HTTP/1.1; `persistent=false` declares `Connection: close`. `Content-Type` defaults to `application/json`. |
| `http.json_response(status, data, cors?, persistent?)` | `string` | `response()` with the data JSON-encoded. |
| `http.error_response(status, data, cors?, persistent?)` | `string` | `json_response()` wrapping the data as `{"errors": data}`. |
| `http.parse_query_string(query)` | `table` | Decodes `a=1&b=2` into a table; values are URL-decoded. |
| `http.url_decode(str)` | `string` | `%xx` byte escapes. |
| `http.cors_headers(cors)` | `table` | The `Access-Control-*` header set for a config (below). |
| `http.is_preflight(request)` | `boolean` | True for `OPTIONS` requests with both `Origin` and `Access-Control-Request-Method`. |
| `http.preflight_response(cors, persistent?)` | `string` | 200 with an empty body carrying the configured CORS headers - the preflight short-circuit. |

A parsed request is a fresh table:

```lua
request.method              -- "GET" (upper case)
request.path                -- "/counters/hits" (query string removed)
request.version             -- "HTTP/1.1" or "HTTP/1.0"
request.headers             -- { [lower-case name] = value }
request.body                -- "" when absent; a chunked body is decoded
request.raw                 -- the raw bytes (read_request / next_request only)
request.chunked             -- true when the body arrived as chunked
request.persistent_connection -- false for HTTP/1.0, true otherwise
request.query_string        -- "by=2" ("" when absent)
request.query_params        -- { by = "2" } (URL-decoded)
```

A typical connection loop - sequential requests on one connection,
including the requests buffered on the wire, ending on the client's EOF,
a framing error, a request-declared `Connection: close`, or an
HTTP/1.0 connection:

```lua
local function handle_connection(client)
  local conn = http.new_connection(function()
    local chunk, read_err = socket.read(client)
    if not chunk then return nil, read_err end
    return chunk
  end)
  while true do
    local request, err, status = conn:next_request()
    if not request and not status then
      -- EOF before any bytes: a closed or idle client owns the close.
      socket.close(client)
      return
    end
    if not request then
      -- A framing error desynchronises the stream: declare close, stop.
      socket.write(client, http.error_response(status or 400, { err }, nil, false))
      socket.close(client)
      return
    end
    local persistent = request.persistent_connection
      and (request.headers["connection"] or ""):lower() ~= "close"
    if cors and http.is_preflight(request) then
      socket.write(client, http.preflight_response(cors, persistent))
    else
      local ctx = http_context.new(request)
      ctx.env_config = config
      router.handle(ctx)
      socket.write(client, http.response(ctx.status, ctx.res_headers,
                                         ctx.response_body(), cors, persistent))
    end
    if not persistent then
      socket.close(client)  -- HTTP/1.0, or the request declared Connection: close
      return
    end
  end
end
```

## lunet.http_context - per-request context

```lua
local http_context = require("lunet.http_context")
local ctx = http_context.new(request)
```

One fresh table per request, never a global, so concurrent `lunet.spawn`
coroutines never share mutable state.

| Field | Kind | Notes |
|-------|------|-------|
| `ctx.method`, `ctx.path`, `ctx.query`, `ctx.headers`, `ctx.body` | request | Copied from the parsed request; read-only by convention. `ctx.query` is the decoded `query_params` table. |
| `ctx.status` | response | Defaults to `200`; mutated by the router/handlers. |
| `ctx.res_headers` | response | Response header table under construction. |
| `ctx.write(text)` | response | Appends a chunk to the response body (`nil` appends `""`). |
| `ctx.log(level, ...)` | logging | Writes to stderr; `level` is one of `"err"`, `"warn"`, `"notice"`, `"info"`, `"debug"` (anything else raises). |
| `ctx.response_body()` | response | Read back the accumulated `write()` output. |
| `ctx.env_config` | wiring | App config, set by the caller before routing; the router passes it to handlers as their first argument. |

## lunet.http_router - routes and middleware

```lua
local router = require("lunet.http_router")
```

The router is a module-level singleton: route modules register themselves when
they are required, and the connection loop only wires the socket.

```lua
-- routes/articles.lua - registers itself on require
local router = require("lunet.http_router")

router.route("GET", "/articles/:id", function(config, ctx, params)
  return { article = config.articles[params.id] }
end)
```

| Function | Notes |
|----------|-------|
| `router.route(method, pattern, handler)` | Registers a route. Patterns are `/`-separated; a segment starting with `:` captures into `params` (e.g. `/users/:id/posts/:post_id`). Matching is exact on segment count and literal segments. |
| `router.match(method, path)` | Returns `route, params` or `nil, nil`. Method comparison is case-insensitive. |
| `router.handle(ctx)` | Runs the middleware chain, dispatches to the matching route and finalises the response on the context. |
| `router.use(fn)` | Registers before-dispatch middleware (below). |
| `router.reset()` | Drops every route and middleware (tests, hot reload). |

Handler contract - handlers run as `pcall(handler, ctx.env_config, ctx, params)`:

- return a **table**: JSON-encoded as the body; a table carrying a `status`
  field sets the response status, and its `body` field (when present) becomes
  the encoded payload instead
- return a **string**: written raw, status 200, `Content-Type:
  application/json`
- return **anything else** (including nothing): the handler drives the
  response itself via `ctx.write()`/`ctx.status` and the context stands as
  written

Every dispatched response is written through `ctx.write()` with
`Content-Type: application/json`; status 204 writes an empty body. An unknown
path - or a supported path with the wrong method - reports 404 with a
`{"error":"Not found","path":...}` body. A handler or middleware error never
escapes: it is reported via `ctx.log("err", ...)` and answered with 500 and a
`{"error":"Internal server error"}` body.

### Middleware

`router.use(fn)` registers before-dispatch middleware. Middleware runs in
registration order before route dispatch, inside the same error contract as
handlers:

- a middleware may **short-circuit** by returning a table or string - the
  value is finalised exactly like a handler result (including the `{ status,
  body }` unwrap)
- returning `nil`, `false` or nothing continues to the next middleware and
  then dispatch
- a middleware error becomes a logged 500; the route handler is not called

```lua
router.use(function(ctx)
  print(ctx.method, ctx.path)
end)

router.use(function(ctx)
  if ctx.headers["authorization"] == nil then
    return { status = 401, body = { error = "unauthorized" } }
  end
end)
```

## CORS (opt-in, default off)

CORS is stateless and off unless a config table is passed. With a config, the
`Access-Control-*` headers ride on normal responses, and an `OPTIONS`
preflight is answered by `http.preflight_response(cors)` before dispatch.

```lua
local cors = {
  origin = "https://app.example",            -- Access-Control-Allow-Origin
  methods = { "GET", "POST", "PATCH" },      -- or a plain "GET, POST" string
  headers = { "Content-Type", "Authorization" },
  max_age = 600,                             -- Access-Control-Max-Age (preflight)
  credentials = true,                        -- Access-Control-Allow-Credentials: true
}
```

Keys left out of the config produce no header, and a caller-supplied header
always wins over the CORS header for the same key. The wiring in the
connection loop is two lines: short-circuit preflights
(`http.is_preflight` + `http.preflight_response`), and pass the config as
the fourth argument of `http.response`/`http.json_response`/
`http.error_response` for everything else (the optional `persistent` flag
comes last).

## Demo

[`examples/08_http.lua`](../examples/08_http.lua) wires the whole trio to
`lnt_shared` counters as a contrived kv store - GET reads a counter, POST
increments it, PATCH adjusts it by a JSON delta - with a logging middleware, a
403 short-circuit guard, CORS enabled, and one keep-alive exchange (two
requests served sequentially on a single connection):

```bash
xmake build-release          # also copies the ext/http Lua modules beside lunet-run
xmake build-lnt-shared       # builds the counters' backing store
"$LUNET_BIN" examples/08_http.lua
```

## Types

LuaCATS annotations live on every public function in the extension files; a
Teal mirror is provided at [`types/lunet/http.d.tl`](../types/lunet/http.d.tl).
Place `types/` in your editor's workspace library for completion and signature
help (see [docs/RELEASE-LAYOUT.md](RELEASE-LAYOUT.md)).
