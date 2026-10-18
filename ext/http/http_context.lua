--[[
lunet.http_context  -  per-request HTTP request context (pure Lua)

Ported from the RealWorld demo application's lib/http_context.lua,
unchanged in behaviour.

One fresh table per request, never a global, so concurrent lunet
coroutines never share mutable state.

Request fields (read-only by convention):
  method, path, query (table of query params), headers, body

Response fields (mutated by the router/handlers):
  status        - HTTP status code, defaults to 200
  res_headers   - response headers table
  write(text)   - append a chunk to the response body
  log(level, ..)- log to stderr; level is a string ("err", "notice", ...)
  env_config    - app config, set by the caller before routing; the router
                  passes it to handlers as their first argument

The connection loop reads the result back via ctx.status /
ctx.res_headers / ctx.response_body().
]]

local LOG_LEVELS = { err = true, warn = true, notice = true, info = true, debug = true }

local http_context = {}

---@class lunet.http_context.HttpContext
---@field method string HTTP method (upper case)
---@field path string request path without the query string
---@field query table<string, string> decoded query parameters
---@field headers table<string, string> request headers, lower-case names
---@field body string request body ("" when absent)
---@field status integer response status code, defaults to 200
---@field res_headers table<string, string> response headers under construction
---@field env_config any? app config, set by the caller before routing
---@field write fun(text: string?) append a chunk to the response body
---@field log fun(level: string, ...) log to stderr; level is "err"|"warn"|"notice"|"info"|"debug"
---@field response_body fun(): string read back the accumulated write() output

---Create a fresh request context from a parsed request (the table
---returned by lunet.http's parse_request / read_request).
---@param request lunet.http.Request A parsed request
---@return lunet.http_context.HttpContext ctx One fresh context table
---@usage
---```lua
---local http_context = require("lunet.http_context")
---local ctx = http_context.new(request)
---ctx.env_config = config
---router.handle(ctx)
---socket.write(client, http.response(ctx.status, ctx.res_headers, ctx.response_body()))
---```
function http_context.new(request)
    local response_body = {}

    local ctx = {
        method = request.method,
        path = request.path,
        query = request.query_params,
        headers = request.headers,
        body = request.body,

        status = 200,
        res_headers = {},
    }

    function ctx.write(text)
        response_body[#response_body + 1] = text or ""
    end

    function ctx.log(level, ...)
        assert(LOG_LEVELS[level], "unknown log level: " .. tostring(level))
        local args = { ... }
        for i, v in ipairs(args) do args[i] = tostring(v) end
        io.stderr:write("[", level, "] ", table.concat(args), "\n")
    end

    -- Read back the accumulated write() output (connection loop only)
    function ctx.response_body()
        return table.concat(response_body)
    end

    return ctx
end

return http_context
