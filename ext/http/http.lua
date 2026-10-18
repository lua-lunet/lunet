--[[
lunet.http — HTTP/1.1 request parsing and response building (pure Lua)

Ported from the RealWorld demo application's lib/http.lua, stripped of
application-specific shapes. Framing, limits and response building are
unchanged; opt-in CORS helpers were added.

Framing subset (deliberately small and explicit):
  - origin-form requests, CRLF header lines; one connection serves
    requests sequentially until the connection closes
  - at most one value per header field, optional decimal Content-Length
  - chunked and every other Transfer-Encoding are rejected
  - connections are persistent by default (HTTP/1.1); pass
    persistent=false to the response builders for "Connection: close" —
    a request declaring close gets one, and the caller stops serving
  - pipelining is excluded: bytes running past the end of a request body
    are a hard 400. The caller closes the socket after writing a close
    response or on a framing error.

Limits guard the parser: MAX_HEADER_BYTES (16 KiB) and MAX_BODY_BYTES
(1 MiB). Oversize headers fail with 431, oversize bodies with 413.

CORS is opt-in and stateless (default off, no magic): pass a cors config
table ({ origin, methods, headers, max_age, credentials }) as the last
argument of response()/json_response()/error_response() to have the
headers added to normal responses, answer an OPTIONS preflight request
with preflight_response() after detecting it with is_preflight(). The
wiring lives with the caller (a connection loop, or middleware on
lunet.http_router).

The JSON helpers require("lunet.jsonic") lazily; everything else in this
module is dependency-free.
]]

local http = {}

---@class lunet.http.Request
---@field method string HTTP method (upper case)
---@field path string request path without the query string
---@field version string always "HTTP/1.1"
---@field headers table<string, string> header fields, lower-case names
---@field body string request body ("" when absent)
---@field raw string the raw request bytes as received
---@field query_params table<string, string> decoded query parameters
---@field query_string string raw query string ("" when absent)

---@class lunet.http.Cors
---@field origin string? value for Access-Control-Allow-Origin
---@field methods string|string[]? value(s) for Access-Control-Allow-Methods
---@field headers string|string[]? value(s) for Access-Control-Allow-Headers
---@field max_age integer? value for Access-Control-Max-Age
---@field credentials boolean? when true, adds Access-Control-Allow-Credentials: true

-- This module deliberately supports a small, explicit HTTP/1.1 framing
-- subset: origin-form requests, CRLF headers, at most one value for each
-- header field, and an optional decimal Content-Length body. Chunked and
-- every other Transfer-Encoding are rejected. Connections are persistent
-- by default (HTTP/1.1); pass persistent=false to the response builders
-- for a "Connection: close" response. Pipelining is excluded: a chunk
-- that runs past the end of a request body is a hard 400.
http.MAX_HEADER_BYTES = 16 * 1024
http.MAX_BODY_BYTES = 1024 * 1024

local function request_error(message, status)
    return nil, message, status or 400
end

local function parse_content_length(value)
    if not value:match("^%d+$") then
        return request_error("Invalid Content-Length")
    end

    local length = 0
    for i = 1, #value do
        length = length * 10 + tonumber(value:sub(i, i))
        if length > http.MAX_BODY_BYTES then
            return request_error("Request body too large", 413)
        end
    end
    return length
end

local function parse_request_head(head)
    local first_line, headers_raw = head:match("^([^\r\n]*)\r\n(.*)$")
    first_line = first_line or head
    headers_raw = headers_raw or ""

    local method, path, version = first_line:match("^([!#$%%&'%*%+%-%._%^_`|~%w]+) ([^ %c]+) (HTTP/%d+%.%d+)$")
    if not method or path:sub(1, 1) ~= "/" then
        return request_error("Invalid HTTP request")
    end
    if version ~= "HTTP/1.1" then
        return request_error("Only HTTP/1.1 is supported", 505)
    end

    local headers = {}
    if headers_raw ~= "" then
        for line in (headers_raw .. "\r\n"):gmatch("(.-)\r\n") do
            local name, value = line:match("^([^:]+):(.*)$")
            if not name or not name:match("^[!#$%%&'%*%+%-%._%^_`|~%w]+$") then
                return request_error("Invalid HTTP header")
            end

            local key = name:lower()
            if headers[key] ~= nil then
                return request_error("Duplicate HTTP header")
            end
            headers[key] = value:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
        end
    end

    if not headers.host or headers.host == "" then
        return request_error("Missing Host header")
    end
    if headers["transfer-encoding"] then
        return request_error("Transfer-Encoding is not supported")
    end

    local content_length = 0
    if headers["content-length"] then
        local length, length_err, length_status = parse_content_length(headers["content-length"])
        if length == nil then return nil, length_err, length_status end
        content_length = length
    end

    local query_string = ""
    local query_start = path:find("?", 1, true)
    if query_start then
        query_string = path:sub(query_start + 1)
        path = path:sub(1, query_start - 1)
    end

    return {
        method = method,
        path = path,
        version = version,
        headers = headers,
        content_length = content_length,
        query_params = http.parse_query_string(query_string),
        query_string = query_string,
    }
end

local function parse_complete_request(raw)
    local request, parse_err, parse_status = http.parse_request(raw)
    if request then request.raw = raw end
    return request, parse_err, parse_status
end

---Parse a query string into a key/value table. Keys and values are URL
---decoded. Repeated keys keep the last value.
---@param query string? Raw query string (without the leading "?"); nil or "" yields an empty table
---@return table<string, string> params
---@usage
---```lua
---local http = require("lunet.http")
---local params = http.parse_query_string("name=Ann&tag=a%20b")
---print(params.name, params.tag)  --> "Ann"  "a b"
---```
function http.parse_query_string(query)
    if not query or query == "" then return {} end
    local params = {}
    for k, v in query:gmatch("([^&=]+)=([^&=]*)") do
        params[http.url_decode(k)] = http.url_decode(v)
    end
    return params
end

---URL-decode a string: "%xx" byte escapes. "+" is left as-is.
---@param str string The percent-encoded string
---@return string decoded
---@usage
---```lua
---local http = require("lunet.http")
---print(http.url_decode("a%20b"))  --> "a b"
---```
function http.url_decode(str)
    return str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

---Parse one complete raw request (head + body). The body must exactly
---match the declared Content-Length: short bodies report "Incomplete
---request body", extra bytes report "Unexpected data after request
---body". On failure returns nil, an error message and an HTTP status.
---@param raw string The raw request bytes
---@return lunet.http.Request|nil request The parsed request, or nil on failure
---@return string|nil err Error message on failure
---@return integer|nil status HTTP status to answer with on failure (400, 413, 431, 505)
---@usage
---```lua
---local http = require("lunet.http")
---local request = http.parse_request("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
---print(request.method, request.path)  --> "GET"  "/x"
---```
function http.parse_request(raw)
    if type(raw) ~= "string" then return request_error("Invalid HTTP request") end

    -- Find end of headers (blank line = double CRLF)
    local header_end = raw:find("\r\n\r\n", 1, true)
    if not header_end then
        if #raw > http.MAX_HEADER_BYTES then
            return request_error("Request headers too large", 431)
        end
        return request_error("Incomplete headers")
    end
    if header_end + 3 > http.MAX_HEADER_BYTES then
        return request_error("Request headers too large", 431)
    end

    local head = raw:sub(1, header_end - 1)
    local body = raw:sub(header_end + 4)

    local request, parse_err, parse_status = parse_request_head(head)
    if not request then return nil, parse_err, parse_status end
    if #body < request.content_length then
        return request_error("Incomplete request body")
    end
    if #body > request.content_length then
        return request_error("Unexpected data after request body")
    end

    request.body = body
    request.content_length = nil
    return request
end

---Incrementally read exactly one supported request from a stream. The
---reader is called repeatedly until the request is complete; it must
---return a string chunk, or nil plus an optional error string on
---EOF/failure. Header and body size limits apply as in parse_request.
---@param read_chunk fun(): string|nil, string? Chunk reader; returns a string chunk or nil on EOF/failure
---@return lunet.http.Request|nil request The parsed request (with .raw), or nil on failure
---@return string|nil err The reader's error on EOF before any bytes, otherwise a framing error message
---@return integer|nil status HTTP status to answer with on failure
---@usage
---```lua
---local http = require("lunet.http")
---local request = http.read_request(function()
---    local chunk, err = socket.read(client)
---    if not chunk then return nil, err end
---    return chunk
---end)
---```
function http.read_request(read_chunk)
    local header_chunks = {}
    local header_size = 0
    local request_head
    local body_chunks
    local body_size = 0
    local expected_body_size
    local saw_bytes = false

    while true do
        local chunk, read_err = read_chunk()
        if not chunk then
            if not saw_bytes then return nil, read_err end
            return request_error(read_err or "Incomplete HTTP request")
        end
        if type(chunk) ~= "string" then
            return request_error("Invalid socket read")
        end
        saw_bytes = true

        if not request_head then
            header_chunks[#header_chunks + 1] = chunk
            header_size = header_size + #chunk
            local received = table.concat(header_chunks)
            local header_end = received:find("\r\n\r\n", 1, true)
            if not header_end then
                if header_size > http.MAX_HEADER_BYTES then
                    return request_error("Request headers too large", 431)
                end
            else
                if header_end + 3 > http.MAX_HEADER_BYTES then
                    return request_error("Request headers too large", 431)
                end

                request_head = received:sub(1, header_end - 1)
                local request, parse_err, parse_status = parse_request_head(request_head)
                if not request then return nil, parse_err, parse_status end
                expected_body_size = request.content_length

                body_chunks = { received:sub(header_end + 4) }
                body_size = #body_chunks[1]
                if body_size > http.MAX_BODY_BYTES then
                    return request_error("Request body too large", 413)
                end
                if body_size > expected_body_size then
                    return request_error("Unexpected data after request body")
                end
                if body_size == expected_body_size then
                    local raw = received:sub(1, header_end + 3) .. table.concat(body_chunks)
                    return parse_complete_request(raw)
                end
            end
        else
            body_size = body_size + #chunk
            if body_size > http.MAX_BODY_BYTES then
                return request_error("Request body too large", 413)
            end
            body_chunks[#body_chunks + 1] = chunk

            if body_size > expected_body_size then
                return request_error("Unexpected data after request body")
            end
            if body_size == expected_body_size then
                local raw = request_head .. "\r\n\r\n" .. table.concat(body_chunks)
                return parse_complete_request(raw)
            end
        end
    end
end

---Build one HTTP/1.1 response string: Content-Length comes from the
---body, the connection is persistent by default, Content-Type defaults
---to "application/json". With a cors config table, the CORS headers
---are added for keys the caller did not set.
---@param status integer HTTP status code
---@param headers table<string, string>? Response headers (names are lower-cased)
---@param body string? Response body ("" when nil)
---@param cors lunet.http.Cors? Opt-in CORS configuration; nil adds nothing
---@param persistent boolean? nil or true leave the connection persistent (no Connection header); false declares "Connection: close"
---@return string response The complete response, ready to write to the socket
---@usage
---```lua
---local http = require("lunet.http")
---socket.write(client, http.response(200, nil, "ok", cors))
---socket.write(client, http.response(200, nil, "bye", nil, false))  -- close
---```
function http.response(status, headers, body, cors, persistent)
    local status_text = {
        [200] = "OK",
        [201] = "Created",
        [204] = "No Content",
        [400] = "Bad Request",
        [401] = "Unauthorized",
        [403] = "Forbidden",
        [404] = "Not Found",
        [405] = "Method Not Allowed",
        [413] = "Payload Too Large",
        [422] = "Unprocessable Entity",
        [431] = "Request Header Fields Too Large",
        [500] = "Internal Server Error",
        [505] = "HTTP Version Not Supported",
    }

    local status_line = string.format("HTTP/1.1 %d %s", status, status_text[status] or "Unknown")

    local normalized_headers = {}
    for name, value in pairs(headers or {}) do
        local key = tostring(name):lower()
        -- Framing is owned by this function: no duplicate content length
        -- or conflicting persistent-connection declaration can be emitted.
        if key ~= "content-length" and key ~= "connection" then
            normalized_headers[key] = value
        end
    end
    if cors then
        -- CORS headers are opt-in and lose to caller-supplied headers.
        for key, value in pairs(http.cors_headers(cors)) do
            if normalized_headers[key] == nil then
                normalized_headers[key] = value
            end
        end
    end
    normalized_headers["content-type"] = normalized_headers["content-type"] or "application/json"
    if persistent == false then
        normalized_headers["connection"] = "close"
    end

    -- Build header lines
    local header_lines = { status_line }
    for k, v in pairs(normalized_headers) do
        header_lines[#header_lines + 1] = string.format("%s: %s", k, tostring(v))
    end

    body = body or ""
    header_lines[#header_lines + 1] = string.format("Content-Length: %d", #body)

    return table.concat(header_lines, "\r\n") .. "\r\n\r\n" .. body
end

---Build the CORS response headers for a configuration. Fields omitted
---from the configuration are omitted from the result; an empty or nil
---configuration yields an empty table (CORS off).
---@param cors lunet.http.Cors? The CORS configuration
---@return table<string, string> headers The Access-Control-* headers (lower-case names)
---@usage
---```lua
---local http = require("lunet.http")
---local cors = { origin = "https://app.example", methods = { "GET", "POST" } }
---print(http.cors_headers(cors)["access-control-allow-origin"])
---```
function http.cors_headers(cors)
    if type(cors) ~= "table" then return {} end
    local function join(value)
        if type(value) == "table" then return table.concat(value, ", ") end
        return tostring(value)
    end
    local out = {}
    if cors.origin ~= nil then
        out["access-control-allow-origin"] = tostring(cors.origin)
    end
    if cors.methods ~= nil then
        out["access-control-allow-methods"] = join(cors.methods)
    end
    if cors.headers ~= nil then
        out["access-control-allow-headers"] = join(cors.headers)
    end
    if cors.max_age ~= nil then
        out["access-control-max-age"] = tostring(cors.max_age)
    end
    if cors.credentials then
        out["access-control-allow-credentials"] = "true"
    end
    return out
end

---Whether a parsed request is a CORS preflight: method OPTIONS with both
---an Origin and an Access-Control-Request-Method header. Plain OPTIONS
---requests without both headers are not preflights.
---@param request lunet.http.Request A parsed request
---@return boolean is_preflight
---@usage
---```lua
---local http = require("lunet.http")
---if http.is_preflight(request) then
---    socket.write(client, http.preflight_response(cors))
---    return
---end
---```
function http.is_preflight(request)
    if type(request) ~= "table" then return false end
    if request.method ~= "OPTIONS" then return false end
    local headers = request.headers
    if type(headers) ~= "table" then return false end
    local origin = headers.origin
    local requested_method = headers["access-control-request-method"]
    return origin ~= nil and origin ~= ""
        and requested_method ~= nil and requested_method ~= ""
end

---Build the short-circuit answer for a CORS preflight request: a 200
---with an empty body carrying the configured CORS headers. Only call
---this when is_preflight(request) is true and CORS is configured;
---without a cors config the response carries no CORS headers.
---@param cors lunet.http.Cors? The CORS configuration
---@param persistent boolean? nil or true leave the connection persistent (no Connection header); false declares "Connection: close"
---@return string response The preflight response, ready to write to the socket
---@usage
---```lua
---local http = require("lunet.http")
---socket.write(client, http.preflight_response(cors))
---```
function http.preflight_response(cors, persistent)
    return http.response(200, http.cors_headers(cors), "", nil, persistent)
end

---Encode data as JSON and build the response. Requires lunet.jsonic
---(lazily). Passing a cors config adds the CORS headers (opt-in).
---@param status integer HTTP status code
---@param data any The value to JSON-encode as the body
---@param cors lunet.http.Cors? Opt-in CORS configuration
---@param persistent boolean? nil or true leave the connection persistent (no Connection header); false declares "Connection: close"
---@return string response The complete response
---@usage
---```lua
---local http = require("lunet.http")
---socket.write(client, http.json_response(200, { ok = true }))
---```
function http.json_response(status, data, cors, persistent)
    local json = require("lunet.jsonic")
    local body = json.encode(data)
    return http.response(status, { ["Content-Type"] = "application/json" }, body, cors, persistent)
end

---JSON error response in the {"errors": ...} envelope shared by the
---router and its handlers. Passing a cors config adds the CORS headers
---(opt-in).
---@param status integer HTTP status code
---@param data any The value for the "errors" field
---@param cors lunet.http.Cors? Opt-in CORS configuration
---@param persistent boolean? nil or true leave the connection persistent (no Connection header); false declares "Connection: close"
---@return string response The complete response
---@usage
---```lua
---local http = require("lunet.http")
---socket.write(client, http.error_response(404, { "no such route" }))
---```
function http.error_response(status, data, cors, persistent)
    return http.json_response(status, { errors = data }, cors, persistent)
end

return http
