-- lunet-mcp-openalex: a tiny localhost MCP server over Streamable HTTP.
--
-- Tools: openalex_search_works, openalex_get_work, openalex_search_authors.
-- No database, no filesystem state; the only outbound calls go to
-- https://api.openalex.org via lunet.httpc (libcurl).
--
-- This example is deliberately legacy-free: it speaks the Streamable HTTP
-- transport only (MCP spec 2025-03-26) to stay small. The fuller demo at
-- https://github.com/lua-lunet/lunet-mcp serves both the legacy HTTP+SSE
-- transport and Streamable HTTP side by side.
--
-- Requires: xmake build-release  (and a release build of lunet-run)
--           xmake build lunet-httpc
-- Config:   OPEN_ALEX_API_KEY in .env (free at https://openalex.org/settings/api)
--           MCP_PORT (optional, default 39281)
--
-- Loopback only: this server binds 127.0.0.1 and nothing else.

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path

local lunet = require("lunet")
local socket = require("lunet.socket")
local http = require("lunet.http")
local jsonic = require("lunet.jsonic")

local dotenv = require("dotenv")
local openalex = require("openalex")
local mcp = require("mcp")

math.randomseed(os.time() * 1000000 + math.floor(os.clock() * 1000000))

local vars = dotenv.load(".env")
local api_key = dotenv.get(vars, "OPEN_ALEX_API_KEY")
local port = tonumber(dotenv.get(vars, "MCP_PORT") or "") or 39281

local api, api_err = openalex.new(api_key)
if not api then
    io.stderr:write("mcp-openalex: " .. tostring(api_err) .. "\n")
    __lunet_exit_code = 1
    return
end

local rpc = mcp.new(api)

-- ---------------------------------------------------------------- sessions

-- Streamable HTTP sessions, minted on `initialize`, checked on every
-- subsequent POST, closed by DELETE /mcp.
local sessions = {}

local function random_session_id()
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local id = {}
    for i = 1, 16 do
        local idx = math.random(1, #chars)
        id[i] = chars:sub(idx, idx)
    end
    return table.concat(id)
end

-- ---------------------------------------------------------------- POST /mcp

-- One JSON-RPC request (or a batch) answered on this same response, with
-- an application/json body or an SSE-formatted body when the client's
-- Accept header asks for text/event-stream.
local function handle_mcp_post(client, request)
    local persistent = request.persistent_connection
        and (request.headers["connection"] or ""):lower() ~= "close"

    local function respond_json(status, body, extra_headers)
        socket.write(client, http.response(status, extra_headers, body, nil, persistent))
        return persistent and "keep" or "close"
    end

    if not request.body or request.body == "" then
        return respond_json(400, mcp.encode_error(nil, -32600, "Invalid Request: empty body"))
    end

    local ok, msg = pcall(jsonic.decode, request.body)
    if not ok or type(msg) ~= "table" or msg == jsonic.null then
        return respond_json(400, mcp.encode_error(nil, -32700, "Parse error"))
    end

    local messages, is_batch = { msg }, false
    if msg[1] ~= nil then
        is_batch = true
        messages = msg
    end

    local has_initialize = false
    for _, m in ipairs(messages) do
        if type(m) == "table" and m.method == "initialize" then
            has_initialize = true
        end
    end

    if not has_initialize then
        local session_id = request.headers["mcp-session-id"]
        if not session_id or session_id == "" then
            return respond_json(400, mcp.encode_error(nil, -32600, "Missing Mcp-Session-Id header"))
        end
        if not sessions[session_id] then
            return respond_json(404, mcp.encode_error(nil, -32600, "Session not found"))
        end
    end

    local responses = {}
    for _, m in ipairs(messages) do
        local response = rpc.dispatch(m)
        if response then
            responses[#responses + 1] = rpc.encode(response)
        end
    end

    local extra_headers = {}
    if has_initialize then
        local session_id = random_session_id()
        sessions[session_id] = { created = os.time() }
        extra_headers["Mcp-Session-Id"] = session_id
    end

    -- Notifications are answered 202 Accepted with no body.
    if #responses == 0 then
        return respond_json(202, "", extra_headers)
    end

    if (request.headers["accept"] or ""):find("text/event-stream", 1, true) then
        local head = "HTTP/1.1 200 OK\r\n" ..
            "Content-Type: text/event-stream\r\n" ..
            "Cache-Control: no-cache\r\n" ..
            "Connection: close\r\n"
        for k, v in pairs(extra_headers) do
            head = head .. k .. ": " .. v .. "\r\n"
        end
        socket.write(client, head .. "\r\n")
        for _, r in ipairs(responses) do
            socket.write(client, "event: message\ndata: " .. r .. "\n\n")
        end
        socket.close(client)
        return "close"
    end

    local body = responses[1]
    if is_batch then
        body = "[" .. table.concat(responses, ",") .. "]"
    end
    return respond_json(200, body, extra_headers)
end

-- ---------------------------------------------------------------- DELETE /mcp

local function handle_mcp_delete(client, request)
    local session_id = request.headers["mcp-session-id"]
    if session_id and sessions[session_id] then
        sessions[session_id] = nil
        socket.write(client, http.response(200, {}, "", nil, false))
    else
        socket.write(client, http.response(404, {}, "", nil, false))
    end
    return "close"
end

-- ---------------------------------------------------------------- routes

-- Route one parsed request. Returns "keep" (serve more requests on this
-- connection) or "close".
local function route_request(client, request)
    if request.path == "/mcp" then
        if request.method == "POST" then
            return handle_mcp_post(client, request)
        elseif request.method == "DELETE" then
            return handle_mcp_delete(client, request)
        end
        socket.write(client, http.response(405, { ["Allow"] = "POST, DELETE" }, "", nil, false))
        return "close"
    end

    if request.path == "/" and request.method == "GET" then
        socket.write(client, http.json_response(200, {
            name = "lunet-mcp-openalex",
            transport = "streamable-http",
            protocolVersion = "2025-03-26",
            endpoint = "/mcp",
            tools = { "openalex_search_works", "openalex_get_work", "openalex_search_authors" },
        }, nil, false))
        return "close"
    end

    socket.write(client, http.error_response(404, { "use POST /mcp (Streamable HTTP)" }, nil, false))
    return "close"
end

-- One connection, sequential requests until the client closes, a framing
-- error, or a request that consumes the connection.
local function handle_client(client)
    local conn = http.new_connection(function()
        local chunk, read_err = socket.read(client)
        if not chunk then return nil, read_err end
        return chunk
    end)

    while true do
        local request, err, status = conn:next_request()
        if not request and not status then
            socket.close(client)
            return
        end
        if not request then
            socket.write(client, http.error_response(status or 400, { err }, nil, false))
            socket.close(client)
            return
        end

        local outcome = route_request(client, request)
        if outcome ~= "keep"
            or not request.persistent_connection
            or (request.headers["connection"] or ""):lower() == "close" then
            socket.close(client)
            return
        end
    end
end

-- ---------------------------------------------------------------- main

lunet.spawn(function()
    local listener, lerr = socket.listen("tcp", "127.0.0.1", port)
    if not listener then
        io.stderr:write("mcp-openalex: listen failed: " .. tostring(lerr) .. "\n")
        __lunet_exit_code = 1
        return
    end

    print("mcp-openalex listening on http://127.0.0.1:" .. port .. "/mcp")
    print("tools: openalex_search_works, openalex_get_work, openalex_search_authors")

    while true do
        local conn = socket.accept(listener)
        if conn then
            lunet.spawn(function()
                handle_client(conn)
            end)
        end
    end
end)
