-- lunet-mcp-openalex: a tiny localhost MCP server over SSE.
--
-- Tools: openalex_search_works, openalex_get_work, openalex_search_authors.
-- No database, no filesystem state; the only outbound calls go to
-- https://api.openalex.org via lunet.httpc (libcurl).
--
-- Requires: xmake build lunet-httpc  (and a release build of lunet-run)
-- Config:   OPEN_ALEX_API_KEY in .env (free at https://openalex.org/settings/api)
--           MCP_PORT (optional, default 39281)
--
-- Loopback only: this server binds 127.0.0.1 and nothing else.

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path

local lunet = require("lunet")
local socket = require("lunet.socket")

local dotenv = require("dotenv")
local openalex = require("openalex")
local mcp = require("mcp")
local sse = require("sse")

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

-- ---------------------------------------------------------------- HTTP

local MAX_REQUEST_BYTES = 1024 * 1024

-- Reads one HTTP request. Returns method, path, body or nil on disconnect.
local function read_request(conn)
    local chunks = {}
    local size = 0
    while size < MAX_REQUEST_BYTES do
        local data = socket.read(conn)
        if not data then return nil end
        chunks[#chunks + 1] = data
        size = size + #data
        local buf = table.concat(chunks)
        local head_end = buf:find("\r\n\r\n", 1, true)
        if head_end then
            local head = buf:sub(1, head_end)
            local content_length = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
            if #buf - (head_end + 3) >= content_length then
                local request_line = head:match("^([^\r\n]+)")
                if not request_line then return nil end
                local method, path = request_line:match("^(%w+)%s+(%S+)")
                if not method then return nil end
                local body = buf:sub(head_end + 4, head_end + 3 + content_length)
                return method, path, body
            end
        end
    end
    return nil
end

local function respond(conn, status, body, content_type)
    body = body or ""
    local response = "HTTP/1.1 " .. status .. "\r\n" ..
        "Content-Type: " .. (content_type or "text/plain") .. "\r\n" ..
        "Content-Length: " .. #body .. "\r\n" ..
        "Connection: close\r\n\r\n" .. body
    socket.write(conn, response)
    socket.close(conn)
end

-- ---------------------------------------------------------------- routes

local function handle_sse(conn)
    local headers = "HTTP/1.1 200 OK\r\n" ..
        "Content-Type: text/event-stream\r\n" ..
        "Cache-Control: no-cache\r\n" ..
        "Connection: keep-alive\r\n\r\n"
    local werr = socket.write(conn, headers) -- nil on success
    if werr then
        socket.close(conn)
        return
    end
    local session = sse.create(conn)
    sse.pump(session, "/message?sessionId=" .. session.id)
    socket.close(conn)
end

local function handle_message(conn, query)
    local session_id = query and query:match("sessionId=([%w%-]+)")
    local session = sse.find(session_id)
    if not session then
        respond(conn, "404 Not Found", '{"error":"unknown session"}', "application/json")
        return
    end
    return session
end

local function handle_connection(conn)
    local method, path, body = read_request(conn)
    if not method then
        socket.close(conn)
        return
    end
    local route, query = path:match("^([^?]+)%??(.*)$")
    if not route then route, query = path, "" end
    if method == "GET" and route == "/sse" then
        handle_sse(conn)
    elseif method == "POST" and route == "/message" then
        local session = handle_message(conn, query)
        if session then
            local payload = rpc.handle_body(body)
            if payload then
                sse.push(session, payload)
            end
            respond(conn, "202 Accepted", "Accepted\n")
        end
    else
        respond(conn, "404 Not Found",
            '{"error":"use GET /sse and POST /message"}', "application/json")
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

    print("mcp-openalex listening on http://127.0.0.1:" .. port .. "/sse")
    print("tools: openalex_search_works, openalex_get_work, openalex_search_authors")

    while true do
        local conn = socket.accept(listener)
        if conn then
            lunet.spawn(function()
                handle_connection(conn)
            end)
        end
    end
end)
