--[[
lunet.http_router — method+path dispatch with :param extraction

Ported from the RealWorld demo application's app/router.lua and
generalised. The router is a module-level singleton: route modules
register themselves with router.route() when they are required, then the
connection loop calls router.handle(ctx) once per request.

Contract:
  - Routes: router.route(method, pattern, handler). Patterns are
    "/"-separated; a pattern segment starting with ":" captures the
    corresponding request segment into the params table (for example
    "/users/:id/posts/:post_id"). Matching is exact on segment count and
    literal segments; a path that matches a pattern only with a
    different method reports 404.
  - Registration on require: because routes live in this singleton,
    a route module registers its routes as a side effect of requiring
    it — the connection loop only wires the socket.
  - Handlers run as pcall(handler, ctx.env_config, ctx, params) and may
      * return a table: JSON-encoded as the body; a table carrying a
        status field sets the response status, and its body field (when
        present) becomes the encoded payload instead
      * return a string: written raw with status 200 (Content-Type stays
        application/json)
      * return anything else (including nothing): the handler drives the
        response itself via ctx.write()/ctx.status and the context
        stands as written
  - Middleware: router.use(fn) registers before-dispatch middleware,
    run in registration order before route dispatch. A middleware may
    short-circuit by returning a table or string — finalised exactly
    like a handler result; returning nil, false or nothing continues to
    the next middleware and then dispatch. Middleware runs inside the
    same error contract as handlers: a middleware error becomes a 500.
  - No route matches (including method mismatches): 404 with a JSON
    {"error":"Not found","path":...} body.
  - Handler or middleware error: 500 with a JSON
    {"error":"Internal server error"} body; the error is reported via
    ctx.log("err", ...). It never escapes as a raised error.
  - Every dispatched response is written through ctx.write() with
    Content-Type: application/json; status 204 writes an empty body.

Requires lunet.jsonic lazily for JSON encoding.
]]

local router = {}

-- Routes table - populated by router.route()
local routes = {}
-- Before-dispatch middleware - populated by router.use(), run in order
local middleware = {}

---Register a route. Intended to be called from route modules as a side
---effect of requiring them.
---@param method string HTTP method (GET, POST, etc.; compared case-insensitively)
---@param path string URL path pattern, e.g. "/users/:id"
---@param handler fun(env_config: any, ctx: lunet.http_context.HttpContext, params: table<string, string>): any
---@usage
---```lua
---local router = require("lunet.http_router")
---router.route("GET", "/users/:id", function(config, ctx, params)
---    return { user = { id = params.id } }
---end)
---```
function router.route(method, path, handler)
    assert(type(handler) == "function", "router.route: expected a handler function")
    table.insert(routes, {
        method = method:upper(),
        pattern = path,
        handler = handler
    })
end

---Register before-dispatch middleware. Middleware runs in registration
---order before route dispatch. A middleware may short-circuit by
---returning a table or string (finalised exactly like a handler
---result); returning nil, false or nothing continues.
---@param fn fun(ctx: lunet.http_context.HttpContext): any
---@usage
---```lua
---local router = require("lunet.http_router")
---router.use(function(ctx)
---    if ctx.headers["authorization"] == nil then
---        return { status = 401, body = { error = "unauthorized" } }
---    end
---end)
---```
function router.use(fn)
    assert(type(fn) == "function", "router.use: expected a function")
    middleware[#middleware + 1] = fn
end

---Drop every registered route and middleware (tests, hot reload).
---@usage
---```lua
---local router = require("lunet.http_router")
---router.reset()
---```
function router.reset()
    routes = {}
    middleware = {}
end

-- Match a path against a pattern and extract parameters
-- @param pattern: route pattern (e.g., "/users/:id/posts/:post_id")
-- @param path: request path (e.g., "/users/123/posts/456")
-- @return params: table of parameters, or nil if no match
local function match_pattern(pattern, path)
    local pattern_parts = {}
    for part in pattern:gmatch("[^/]+") do
        table.insert(pattern_parts, part)
    end

    local path_parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(path_parts, part)
    end

    if #pattern_parts ~= #path_parts then
        return nil
    end

    local params = {}
    for i, pp in ipairs(pattern_parts) do
        if pp:sub(1, 1) == ":" then
            params[pp:sub(2)] = path_parts[i]
        elseif pp ~= path_parts[i] then
            return nil
        end
    end

    return params
end

---Find a matching route.
---@param method string HTTP method (compared case-insensitively)
---@param path string request path
---@return table|nil route The route table, or nil
---@return table<string, string>|nil params The captured parameters, or nil
---@usage
---```lua
---local router = require("lunet.http_router")
---local route, params = router.match("GET", "/users/42")
---```
function router.match(method, path)
    for _, route in ipairs(routes) do
        if route.method == method:upper() then
            local params = match_pattern(route.pattern, path)
            if params then
                return route, params
            end
        end
    end
    return nil, nil
end

-- Write the final status + body for a handler/middleware result value:
-- { status = n, body = t } unwraps to (n, t); other tables JSON-encode;
-- strings write raw; 204 writes an empty body.
local function respond_result(ctx, status, result)
    ctx.status = status
    ctx.res_headers["Content-Type"] = "application/json"

    if status == 204 then
        ctx.write("")
        return
    end

    if type(result) == "string" then
        ctx.write(result)
        return
    end

    local json = require("lunet.jsonic")
    local encode_ok, encoded = pcall(json.encode, result)
    if not encode_ok then
        ctx.log("err", "JSON encode error for ", ctx.method, " ", ctx.path, ": ", tostring(encoded))
        ctx.status = 500
        ctx.write('{"error":"Internal server error"}')
        return
    end
    ctx.write(encoded)
end

-- Write the final status + body for a handler/middleware result value:
-- { status = n, body = t } unwraps to (n, t); other tables JSON-encode;
-- strings write raw; 204 writes an empty body. Any other value means
-- the handler drives ctx directly and the response stands as written.
local function respond_value(ctx, result)
    if type(result) ~= "table" and type(result) ~= "string" then
        return
    end
    local status = 200
    if type(result) == "table" and result.status then
        status = result.status
        result = result.body or result
    end
    respond_result(ctx, status, result)
end

---Handle one request: run the middleware chain, dispatch to the
---matching route and finalise the JSON response on the context. Errors
---from handlers or middleware become logged 500 responses and never
---escape as raised errors.
---@param ctx lunet.http_context.HttpContext The request context (env_config set by the caller)
---@usage
---```lua
---local router = require("lunet.http_router")
---router.handle(ctx)
---socket.write(client, http.response(ctx.status, ctx.res_headers, ctx.response_body()))
---```
function router.handle(ctx)
    local method = ctx.method
    local path = ctx.path

    -- Middleware phase (before dispatch, inside the error contract).
    for _, middleware_fn in ipairs(middleware) do
        local middleware_ok, middleware_result = pcall(middleware_fn, ctx)
        if not middleware_ok then
            ctx.log("err", "Middleware error for ", method, " ", path, ": ",
                    tostring(middleware_result))
            respond_result(ctx, 500, { error = "Internal server error" })
            return
        end
        if type(middleware_result) == "table" or type(middleware_result) == "string" then
            respond_value(ctx, middleware_result)
            return
        end
    end

    local route, params = router.match(method, path)
    if not route then
        respond_result(ctx, 404, { error = "Not found", path = path })
        return
    end

    local ok, handler_result = pcall(route.handler, ctx.env_config, ctx, params)
    if not ok then
        ctx.log("err", "Handler error for ", method, " ", path, ": ", tostring(handler_result))
        respond_result(ctx, 500, { error = "Internal server error" })
        return
    end

    respond_value(ctx, handler_result)
end

return router
