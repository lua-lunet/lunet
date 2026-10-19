--[[
lunet.http  -  HTTP/1.x request parsing and response building (pure Lua)

Ported from the RealWorld demo application's lib/http.lua, stripped of
application-specific shapes. Framing, limits and response building are
otherwise unchanged; opt-in CORS helpers were added.

Framing subset (deliberately small and explicit):
  - origin-form requests, CRLF header lines; one connection serves
    requests sequentially until the connection closes
  - at most one value per header field, optional decimal Content-Length
  - Transfer-Encoding: chunked is accepted and the body is de-chunked;
    every other transfer coding is rejected with 501
  - HTTP/1.0 requests with a Host header are accepted and served with
    "Connection: close"; a missing Host is a 400 on every version
  - connections are persistent by default (HTTP/1.1); pass
    persistent=false to the response builders for "Connection: close".
    A request declaring close gets one, HTTP/1.0 gets one, and the
    caller stops serving the connection after writing it
  - requests buffered on the wire are served sequentially: wrap the
    chunk reader with http.new_connection and call next_request() once
    per request; bytes left over by one request are the next one's
    input. The one-shot read_request keeps the older strict contract
    (bytes past the declared body are a 400)

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
---@field version string "HTTP/1.1" or "HTTP/1.0"
---@field headers table<string, string> header fields, lower-case names
---@field body string request body ("" when absent); a chunked body is decoded
---@field raw string the raw request bytes as received
---@field chunked boolean true when the body arrived as Transfer-Encoding: chunked
---@field persistent_connection boolean true for HTTP/1.1, false for HTTP/1.0;
---       combine with the Connection header for the serve/close decision
---@field query_params table<string, string> decoded query parameters
---@field query_string string raw query string ("" when absent)

---@class lunet.http.Cors
---@field origin string? value for Access-Control-Allow-Origin
---@field methods string|string[]? value(s) for Access-Control-Allow-Methods
---@field headers string|string[]? value(s) for Access-Control-Allow-Headers
---@field max_age integer? value for Access-Control-Max-Age
---@field credentials boolean? when true, adds Access-Control-Allow-Credentials: true

-- This module deliberately supports a small, explicit HTTP/1.x framing
-- subset: origin-form requests, CRLF headers, at most one value for each
-- header field, and a body framed by an optional decimal Content-Length
-- or by Transfer-Encoding: chunked (decoded, alone and final). Any other
-- transfer coding is rejected with 501. Connections are persistent by
-- default (HTTP/1.1); HTTP/1.0 connections are served with close. Pass
-- persistent=false to the response builders for a "Connection: close"
-- response. Serve the requests buffered on the wire sequentially through
-- a http.new_connection wrapper.
http.MAX_HEADER_BYTES = 16 * 1024
http.MAX_BODY_BYTES = 1024 * 1024
http.MAX_REQUEST_LINE_BYTES = 8 * 1024

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

-- The accepted transfer coding is exactly "chunked" (case-insensitive,
-- alone and final). Every other coding, alone or combined, stays
-- outside the subset.
local function accept_transfer_encoding(value)
    local trimmed = value:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
    return trimmed:lower() == "chunked"
end

local function parse_request_head(head)
    local first_line, headers_raw = head:match("^([^\r\n]*)\r\n(.*)$")
    first_line = first_line or head
    headers_raw = headers_raw or ""

    local method, path, version = first_line:match("^([!#$%%&'%*%+%-%._%^_`|~%w]+) ([^ %c]+) (HTTP/%d+%.%d+)$")
    if not method or path:sub(1, 1) ~= "/" then
        return request_error("Invalid HTTP request")
    end
    if #first_line > http.MAX_REQUEST_LINE_BYTES then
        return request_error("Request line too long", 414)
    end
    local major = tonumber(version:match("^HTTP/(%d+)%."))
    if major ~= 1 then
        return request_error("HTTP version not supported", 505)
    end
    -- Canonical spellings only: "HTTP/01.01" is not HTTP/1.1.
    if version ~= "HTTP/1.1" and version ~= "HTTP/1.0" then
        return request_error("Only HTTP/1.0 and HTTP/1.1 are supported")
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
    if headers.host:find("[/@]") then
        return request_error("Invalid Host header")
    end

    local chunked = false
    if headers["transfer-encoding"] then
        if not accept_transfer_encoding(headers["transfer-encoding"]) then
            return request_error("Transfer-Encoding is not supported", 501)
        end
        if headers["content-length"] then
            return request_error("Conflicting Content-Length and Transfer-Encoding")
        end
        chunked = true
    end

    local content_length = 0
    if not chunked and headers["content-length"] then
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
        chunked = chunked,
        content_length = content_length,
        persistent_connection = version == "HTTP/1.1",
        query_params = http.parse_query_string(query_string),
        query_string = query_string,
    }
end

-- Read the next framing line of a chunked body from `body` at `pos`.
-- Lines end with CRLF. A bare LF where a line ending is due is framing
-- garbage: it is rejected in place instead of waiting for bytes that
-- never arrive.
-- Returns the index of the line-ending "\n", or on failure:
--   nil, "incomplete", nil       no line ending in the buffer yet
--   nil, err, status             framing failure (400, 431)
local function next_framing_line(body, pos)
    local line_feed = body:find("\n", pos, true)
    if not line_feed then
        if #body - pos + 1 > http.MAX_HEADER_BYTES then
            return nil, "Chunk-size line too large", 431
        end
        return nil, "incomplete"
    end
    if body:sub(line_feed - 1, line_feed - 1) ~= "\r" then
        return nil, "Invalid chunked body", 400
    end
    return line_feed
end

-- Decode one complete Transfer-Encoding: chunked body from the front of
-- `body`. Chunk grammar per request: size line (hex digits, an optional
-- ";extension" suffix, CRLF), chunk data, CRLF; the zero chunk ends in
-- optional trailer lines closed by a blank line.
-- Returns:
--   decoded, rest, nil       a complete chunked body; `rest` is what
--                            follows the last-chunk terminator
--   nil, nil, "incomplete"   the buffer ends inside the framing; feed
--                            more bytes and retry
--   nil, nil, err, status    framing failure (400, 431, 413)
---@param body string The body bytes accumulated so far
---@return string? decoded The decoded body, nil when incomplete or on failure
---@return string? rest The bytes that follow the last-chunk terminator
---@return string|nil err nil ("incomplete") when more bytes are needed, otherwise the failure message
---@return integer|nil status HTTP status to answer with on failure
local function consume_chunked_body(body)
    local pos = 1
    local decoded = {}
    local decoded_size = 0

    while true do
        local line_end, line_err, line_status = next_framing_line(body, pos)
        if not line_end then
            if line_status then
                return nil, nil, line_err, line_status
            end
            return nil, nil, "incomplete"
        end
        local size_line = body:sub(pos, line_end - 2)
        local hex_size, extension = size_line:match("^([%x]+)(;.*)$")
        if not hex_size then
            hex_size = size_line:match("^([%x]+)$") and size_line or nil
            extension = ""
        end
        if not hex_size then
            return nil, nil, "Invalid chunk size", 400
        end
        local size = tonumber(hex_size, 16)

        if size == 0 then
            -- Trailers are syntax-checked and then discarded: a trailer
            -- is never a request header, so it cannot re-frame the
            -- request that announced it.
            local trailer_size = 0
            local trailer_pos = line_end + 1
            while true do
                local trailer_end, trailer_err, trailer_status = next_framing_line(body, trailer_pos)
                if not trailer_end then
                    if trailer_err == "incomplete" then
                        if trailer_size + (#body - trailer_pos + 1) > http.MAX_HEADER_BYTES then
                            return nil, nil, "Trailer headers too large", 431
                        end
                        return nil, nil, "incomplete"
                    end
                    return nil, nil, trailer_err, trailer_status
                end
                trailer_size = trailer_size + (trailer_end + 1 - trailer_pos)
                if trailer_size > http.MAX_HEADER_BYTES then
                    return nil, nil, "Trailer headers too large", 431
                end
                local trailer = body:sub(trailer_pos, trailer_end - 2)
                if trailer == "" then
                    return table.concat(decoded), body:sub(trailer_end + 1)
                end
                if not trailer:match("^[!#$%%&'%*%+%-%._%^_`|~%w]+:.*$") then
                    return nil, nil, "Invalid HTTP header", 400
                end
                trailer_pos = trailer_end + 1
            end
        end

        if decoded_size + size > http.MAX_BODY_BYTES then
            return nil, nil, "Request body too large", 413
        end
        local data_start = line_end + 1
        local data_end = data_start + size - 1
        if #body < data_end + 2 then
            return nil, nil, "incomplete"
        end
        if body:sub(data_end + 1, data_end + 2) ~= "\r\n" then
            return nil, nil, "Invalid chunked body", 400
        end
        decoded[#decoded + 1] = body:sub(data_start, data_end)
        decoded_size = decoded_size + size
        pos = data_end + 3
    end
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
    local decoded = str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return decoded
end

---Parse one complete raw request (head + body). A Content-Length body
---must exactly match the declared length: short bodies report "Incomplete
---request body", extra bytes report "Unexpected data after request
---body". A chunked body is decoded; the buffer must end at the
---last-chunk terminator. HTTP/1.0 requests with a Host header are
---accepted (persistent_connection = false). On failure returns nil, an
---error message and an HTTP status.
---@param raw string The raw request bytes
---@return lunet.http.Request|nil request The parsed request, or nil on failure
---@return string|nil err Error message on failure
---@return integer|nil status HTTP status to answer with on failure (400, 413, 414, 431, 501, 505)
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

    if request.chunked then
        local decoded, rest, decode_err, decode_status = consume_chunked_body(body)
        if not decoded then
            if decode_err == "incomplete" then
                return request_error("Incomplete request body")
            end
            return nil, decode_err, decode_status
        end
        if #rest > 0 then
            return request_error("Unexpected data after request body")
        end
        request.body = decoded
    else
        if #body < request.content_length then
            return request_error("Incomplete request body")
        end
        if #body > request.content_length then
            return request_error("Unexpected data after request body")
        end
        request.body = body
    end

    request.content_length = nil
    request.raw = raw
    return request
end

---Extract one complete request from `buffer`, pulling more bytes with
---`read_chunk` while the buffer ends inside the request. Returns:
---   request, leftover, nil, nil   a request; `leftover` is what follows
---                                 this request's bytes in the wire order
---   nil, "", read_err, nil        EOF with no buffered bytes (read_err
---                                 is nil on a clean EOF)
---   nil, "", err, status          framing failure (400, 413, 414, 431, 501, 505)
---@param read_chunk fun(): string|nil, string? Chunk reader pulled while the buffer is incomplete
---@param buffer string Bytes already received for this request
---@return lunet.http.Request|nil request The parsed request (with .raw), or nil on failure
---@return string leftover The bytes that follow this request's framing, "" when none or on failure
---@return string|nil err The reader's error on EOF before any bytes, otherwise a framing error message
---@return integer|nil status HTTP status to answer with on failure
local function consume_one(read_chunk, buffer)
    local saw_bytes = #buffer > 0

    while true do
        local header_end = buffer:find("\r\n\r\n", 1, true)
        if not header_end then
            if #buffer > http.MAX_HEADER_BYTES then
                return nil, "", "Request headers too large", 431
            end
            local chunk, read_err = read_chunk()
            if chunk == nil then
                if not saw_bytes then return nil, "", read_err end
                return nil, "", read_err or "Incomplete HTTP request", 400
            end
            if type(chunk) ~= "string" then
                return nil, "", "Invalid socket read", 400
            end
            saw_bytes = true
            buffer = buffer .. chunk
        else
            if header_end + 3 > http.MAX_HEADER_BYTES then
                return nil, "", "Request headers too large", 431
            end

            local request, parse_err, parse_status =
                parse_request_head(buffer:sub(1, header_end - 1))
            if not request then return nil, "", parse_err, parse_status end

            local body = buffer:sub(header_end + 4)

            if request.chunked then
                local decoded, rest, decode_err, decode_status = consume_chunked_body(body)
                if not decoded then
                    if decode_err ~= "incomplete" then
                        return nil, "", decode_err, decode_status
                    end
                    local chunk, read_err = read_chunk()
                    if chunk == nil then
                        if not saw_bytes then return nil, "", read_err end
                        return nil, "", read_err or "Incomplete HTTP request", 400
                    end
                    if type(chunk) ~= "string" then
                        return nil, "", "Invalid socket read", 400
                    end
                    saw_bytes = true
                    buffer = buffer .. chunk
                else
                    request.body = decoded
                    request.content_length = nil
                    request.raw = buffer:sub(1, header_end + 3 + (#body - #rest))
                    return request, rest or "", nil, nil
                end
            else
                local content_length = request.content_length
                if #body >= content_length then
                    request.body = body:sub(1, content_length)
                    request.content_length = nil
                    request.raw = buffer:sub(1, header_end + 3 + content_length)
                    return request, body:sub(content_length + 1), nil, nil
                end
                local chunk, read_err = read_chunk()
                if chunk == nil then
                    if not saw_bytes then return nil, "", read_err end
                    return nil, "", read_err or "Incomplete HTTP request", 400
                end
                if type(chunk) ~= "string" then
                    return nil, "", "Invalid socket read", 400
                end
                saw_bytes = true
                buffer = buffer .. chunk
            end
        end
    end
end

---@class lunet.http.Connection
---@field private read_chunk fun(): string|nil, string? the wrapped chunk reader
---@field private buffer string bytes received by earlier requests
local Connection = {}
Connection.__index = Connection

---Serve the next request of a persistent connection. Requests already
---buffered on the wire (pipelining) are answered without blocking on
---the reader; the bytes each request does not consume stay queued for
---this call. A framing error desynchronises the stream: the wrapper
---drops its buffer and the caller answers and closes.
---@return lunet.http.Request|nil request The parsed request (with .raw), or nil when the connection ends
---@return string|nil err The reader's error on EOF before any bytes, otherwise a framing error message
---@return integer|nil status HTTP status to answer with on failure
function Connection:next_request()
    local request, leftover, err, status = consume_one(self.read_chunk, self.buffer)
    if request then
        self.buffer = leftover
        return request
    end
    self.buffer = ""
    return nil, err, status
end

---Wrap a connection's chunk reader for sequential serving. One wrapper
---per open connection; keep it alive for the connection's whole life.
---@param read_chunk fun(): string|nil, string? Chunk reader; returns a string chunk or nil on EOF/failure
---@return lunet.http.Connection connection The connection wrapper
---@usage
---```lua
---local http = require("lunet.http")
---local conn = http.new_connection(function()
---    local chunk, err = socket.read(client)
---    if not chunk then return nil, err end
---    return chunk
---end)
---local request, err, status = conn:next_request()
---```
function http.new_connection(read_chunk)
    return setmetatable({ read_chunk = read_chunk, buffer = "" }, Connection)
end

---Incrementally read exactly one supported request from a stream. The
---reader is called repeatedly until the request is complete; it must
---return a string chunk, or nil plus an optional error string on
---EOF/failure. Header and body size limits apply as in parse_request.
---Bytes past the declared body fail with "Unexpected data after request
---body": to serve a stream that may hold more than one request, wrap
---the reader with http.new_connection instead.
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
    local request, leftover, err, status = consume_one(read_chunk, "")
    if request then
        if #leftover > 0 then
            return request_error("Unexpected data after request body")
        end
        return request
    end
    return nil, err, status
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
        [414] = "URI Too Long",
        [422] = "Unprocessable Entity",
        [431] = "Request Header Fields Too Large",
        [500] = "Internal Server Error",
        [501] = "Not Implemented",
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
    normalized_headers["date"] = normalized_headers["date"] or os.date("!%a, %d %b %Y %H:%M:%S GMT")
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
