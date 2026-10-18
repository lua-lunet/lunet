# lunet.http / lunet.http_context / lunet.http_router

A pure-Lua HTTP/1.1 trio for building small servers on `lunet.socket`:

- [`lunet.http`](#lunethttp--request-framing-and-responses) — request parsing, response building, opt-in CORS
- [`lunet.http_context`](#lunethttpcontext--per-request-context) — one fresh per-request context object
- [`lunet.http_router`](#lunethttprouter--routes-and-middleware) — method+path dispatch with `:params` and middleware

The modules are plain Lua files, no C core and no new dependency: they ship
in the release archives (see [docs/RELEASE-LAYOUT.md](RELEASE-LAYOUT.md) for
the archive map), and `xmake build-release` copies them next to `lunet-run`
from a source tree, where the runtime's `lunet/?.lua` path entry resolves
them. The socket I/O (listen, accept, read, write, close) stays with the
caller; the JSON helpers require `lunet.jsonic` lazily, only when called.

A runnable end-to-end demo lives at [`examples/08_http.lua`](../examples/08_http.lua).

## The framing subset

Deployment security first: the qmail-style model in
[docs/SECURITY_ARCHITECTURE.md](SECURITY_ARCHITECTURE.md) — a battle-hardened
nginx (or similar) terminates the network interface and talks to your lunet
process over the loopback interface, or over a Unix domain socket if you
prefer filesystem permissions to IP rules. This module's server example binds
loopback only; it is not a TLS terminator and never should be.

The framing this module implements is a deliberately small subset of
HTTP/1.1:

The parser deliberately supports a small, explicit HTTP/1.1 subset:

- origin-form requests, CRLF header lines; one connection serves requests
  sequentially, one after another, until the connection closes
- at most one value per header field, optional decimal `Content-Length` body
- `Transfer-Encoding` (including chunked) is rejected
- connections are persistent by default (HTTP/1.1): responses carry no
  `Connection` header. Pass `persistent=false` as the last argument of
  `http.response`/`http.json_response`/`http.error_response` (and
  `http.preflight_response`) for a `Connection: close` response.
- a request declaring `Connection: close` is honoured: build its response
  with `persistent=false` and end the connection loop after writing it
- pipelining is excluded: bytes running past the end of a request body are
  a hard 400 (`"Unexpected data after request body"`). Send the next request
  only after reading the previous response.
- `MAX_HEADER_BYTES` (16 KiB) and `MAX_BODY_BYTES` (1 MiB) guard the parser;
  oversize headers fail with 431, oversize bodies with 413

Parse failures follow the `nil, message, status` convention, so a connection
loop can answer `http.error_response(status, { message })` directly.

## lunet.http — request framing and responses

```lua
local http = require("lunet.http")
```

| Function | Returns | Notes |
|----------|---------|-------|
| `http.parse_request(raw)` | `request, err, status` | Parses one complete raw request (head + body). The body must exactly match `Content-Length`. |
| `http.read_request(read_chunk)` | `request, err, status` | Incremental variant: `read_chunk()` is called until the request is complete and must return a string chunk, or nil plus an optional error on EOF/failure. |
| `http.response(status, headers, body, cors?, persistent?)` | `string` | Builds the full response. Framing is owned here: caller `Content-Length`/`Connection` headers are dropped and replaced (`Content-Length` from the body). The connection is persistent by default — no `Connection` header, per HTTP/1.1; `persistent=false` declares `Connection: close`. `Content-Type` defaults to `application/json`. |
| `http.json_response(status, data, cors?, persistent?)` | `string` | `response()` with the data JSON-encoded. |
| `http.error_response(status, data, cors?, persistent?)` | `string` | `json_response()` wrapping the data as `{"errors": data}`. |
| `http.parse_query_string(query)` | `table` | Decodes `a=1&b=2` into a table; values are URL-decoded. |
| `http.url_decode(str)` | `string` | `%xx` byte escapes. |
| `http.cors_headers(cors)` | `table` | The `Access-Control-*` header set for a config (below). |
| `http.is_preflight(request)` | `boolean` | True for `OPTIONS` requests with both `Origin` and `Access-Control-Request-Method`. |
| `http.preflight_response(cors, persistent?)` | `string` | 200 with an empty body carrying the configured CORS headers — the preflight short-circuit. |

A parsed request is a fresh table:

```lua
request.method        -- "GET" (upper case)
request.path          -- "/counters/hits" (query string removed)
request.version       -- "HTTP/1.1"
request.headers       -- { [lower-case name] = value }
request.body          -- "" when absent
request.raw           -- the raw bytes (read_request only)
request.query_string  -- "by=2" ("" when absent)
request.query_params  -- { by = "2" } (URL-decoded)
```

A typical connection loop — sequential requests on one connection, ending
on the client's EOF, a framing error, or a request-declared
`Connection: close`:

```lua
local function handle_connection(client)
  while true do
    local request, err, status = http.read_request(function()
      local chunk, read_err = socket.read(client)
      if not chunk then return nil, read_err end
      return chunk
    end)
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
    local persistent = (request.headers["connection"] or ""):lower() ~= "close"
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
      socket.close(client)  -- the request declared Connection: close
      return
    end
  end
end
```

## lunet.http_context — per-request context

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

## lunet.http_router — routes and middleware

```lua
local router = require("lunet.http_router")
```

The router is a module-level singleton: route modules register themselves when
they are required, and the connection loop only wires the socket.

```lua
-- routes/articles.lua — registers itself on require
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

Handler contract — handlers run as `pcall(handler, ctx.env_config, ctx, params)`:

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
path — or a supported path with the wrong method — reports 404 with a
`{"error":"Not found","path":...}` body. A handler or middleware error never
escapes: it is reported via `ctx.log("err", ...)` and answered with 500 and a
`{"error":"Internal server error"}` body.

### Middleware

`router.use(fn)` registers before-dispatch middleware. Middleware runs in
registration order before route dispatch, inside the same error contract as
handlers:

- a middleware may **short-circuit** by returning a table or string — the
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
`lnt_shared` counters as a contrived kv store — GET reads a counter, POST
increments it, PATCH adjusts it by a JSON delta — with a logging middleware, a
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
