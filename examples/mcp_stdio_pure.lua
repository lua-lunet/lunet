#!/usr/bin/env lua
-- Pure Lua MCP Stdio Server with Tavily Search
-- NO Lunet, NO libuv - just plain Lua stdin/stdout
--
-- This is an ablation test to measure how much overhead the network stack adds.
-- Compare memory usage of this vs the SSE server to see the networking cost.
--
-- Usage:
--   lua examples/mcp_stdio_pure.lua
--   # Or with LuaJIT:
--   luajit examples/mcp_stdio_pure.lua
--
-- Memory Comparison (measured 2026-01-19):
--
--   Implementation                   RSS (MB)    vs Node.js
--   --------------------------------------------------------
--   Pure Lua stdio (this file)          1.6       24x smaller
--   Lunet SSE server (LuaJIT+libuv)     2.2       18x smaller
--   Official Tavily MCP (Node.js)      38.0       baseline
--
-- Ablation Result:
--   libuv/networking overhead = 2.2 - 1.6 = 0.6 MB (~27% of total)
--   LuaJIT baseline (this file) = 1.6 MB

local MCP_VERSION = "2024-11-05"
local SERVER_NAME = "lua-tavily-mcp-stdio"
local SERVER_VERSION = "1.0.0"

local function load_env_file(path)
    local file = io.open(path, "r")
    if not file then return end
    for line in file:lines() do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key and value then
            value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
            rawset(_G, "_ENV_" .. key, value)
        end
    end
    file:close()
end

local function getenv(key)
    return os.getenv(key) or rawget(_G, "_ENV_" .. key)
end

load_env_file(".env")
local TAVILY_API_KEY = getenv("TAVILY_API_KEY")
if not TAVILY_API_KEY then
    io.stderr:write("WARNING: TAVILY_API_KEY not set. Tavily search will fail.\n")
end

local function escape_json_string(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    s = s:gsub('\b', '\\b')
    s = s:gsub('\f', '\\f')
    return s
end

local function json_encode(val)
    local t = type(val)
    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val then return "null" end
        if val == math.huge or val == -math.huge then return "null" end
        return tostring(val)
    elseif t == "string" then
        return '"' .. escape_json_string(val) .. '"'
    elseif t == "table" then
        local is_array = #val > 0 or next(val) == nil
        if is_array then
            local parts = {}
            for i, v in ipairs(val) do
                parts[i] = json_encode(v)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                if type(k) == "string" then
                    parts[#parts + 1] = '"' .. escape_json_string(k) .. '":' .. json_encode(v)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function json_decode(str)
    local pos = 1
    local function skip_ws()
        pos = str:match("^%s*()", pos)
    end
    local function parse_value()
        skip_ws()
        local c = str:sub(pos, pos)
        if c == '"' then
            local start = pos + 1
            local i = start
            local parts = {}
            while i <= #str do
                local ch = str:sub(i, i)
                if ch == '"' then
                    parts[#parts + 1] = str:sub(start, i - 1)
                    pos = i + 1
                    local result = table.concat(parts)
                    result = result:gsub("\\(.)", function(e)
                        local escapes = {n="\n", r="\r", t="\t", b="\b", f="\f", ['"']='"', ["\\"]="\\", ["/"]="/"}
                        return escapes[e] or e
                    end)
                    return result
                elseif ch == "\\" then
                    parts[#parts + 1] = str:sub(start, i - 1)
                    i = i + 1
                    local esc = str:sub(i, i)
                    if esc == "u" then
                        local hex = str:sub(i + 1, i + 4)
                        local cp = tonumber(hex, 16)
                        if cp then
                            if cp < 0x80 then
                                parts[#parts + 1] = string.char(cp)
                            elseif cp < 0x800 then
                                parts[#parts + 1] = string.char(
                                    0xC0 + math.floor(cp / 64),
                                    0x80 + (cp % 64))
                            else
                                parts[#parts + 1] = string.char(
                                    0xE0 + math.floor(cp / 4096),
                                    0x80 + math.floor((cp % 4096) / 64),
                                    0x80 + (cp % 64))
                            end
                        else
                            parts[#parts + 1] = "?"
                        end
                        i = i + 5
                    else
                        i = i + 1
                    end
                    start = i
                else
                    i = i + 1
                end
            end
            error("Unterminated string")
        elseif c == "{" then
            pos = pos + 1
            local obj = {}
            skip_ws()
            if str:sub(pos, pos) == "}" then
                pos = pos + 1
                return obj
            end
            while true do
                skip_ws()
                local key = parse_value()
                skip_ws()
                if str:sub(pos, pos) ~= ":" then error("Expected ':'") end
                pos = pos + 1
                local val = parse_value()
                obj[key] = val
                skip_ws()
                local sep = str:sub(pos, pos)
                if sep == "}" then
                    pos = pos + 1
                    return obj
                elseif sep == "," then
                    pos = pos + 1
                else
                    error("Expected ',' or '}'")
                end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skip_ws()
            if str:sub(pos, pos) == "]" then
                pos = pos + 1
                return arr
            end
            while true do
                arr[#arr + 1] = parse_value()
                skip_ws()
                local sep = str:sub(pos, pos)
                if sep == "]" then
                    pos = pos + 1
                    return arr
                elseif sep == "," then
                    pos = pos + 1
                else
                    error("Expected ',' or ']'")
                end
            end
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        elseif c == "-" or c:match("%d") then
            local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
            pos = pos + #num_str
            return tonumber(num_str)
        else
            error("Unexpected character: " .. c .. " at position " .. pos)
        end
    end
    return parse_value()
end

local function jsonrpc_response(id, result)
    return json_encode({
        jsonrpc = "2.0",
        id = id,
        result = result,
    })
end

local function jsonrpc_error(id, code, message)
    return json_encode({
        jsonrpc = "2.0",
        id = id,
        error = {
            code = code,
            message = message,
        },
    })
end

local function shell_escape(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function tavily_search(query, max_results)
    if not TAVILY_API_KEY then
        return nil, "TAVILY_API_KEY not configured"
    end

    max_results = max_results or 5
    local request_body = json_encode({
        query = query,
        max_results = max_results,
        include_answer = true,
        search_depth = "basic",
    })

    local cmd = "curl -s -X POST 'https://api.tavily.com/search' " ..
                "-H 'Content-Type: application/json' " ..
                "-H " .. shell_escape("Authorization: Bearer " .. TAVILY_API_KEY) .. " " ..
                "-d " .. shell_escape(request_body)

    local handle = io.popen(cmd)
    if not handle then
        return nil, "Failed to execute curl"
    end

    local response = handle:read("*a")
    handle:close()

    if not response or response == "" then
        return nil, "Empty response from Tavily API"
    end

    local ok, result = pcall(json_decode, response)
    if not ok then
        return nil, "Failed to parse Tavily response: " .. tostring(result)
    end

    if result.error then
        return nil, "Tavily API error: " .. (result.error or "unknown")
    end

    return result
end

local tools = {
    {
        name = "tavily-search",
        description = "Search the web using Tavily AI search engine. Returns relevant web content with titles, URLs, and snippets.",
        inputSchema = {
            type = "object",
            properties = {
                query = {
                    type = "string",
                    description = "The search query",
                },
                max_results = {
                    type = "number",
                    description = "Maximum number of results (1-10, default 5)",
                },
            },
            required = {"query"},
        },
    },
}

local function handle_tool_call(name, arguments)
    if name == "tavily-search" then
        local query = arguments.query
        local max_results = arguments.max_results or 5
        if max_results > 10 then max_results = 10 end
        if max_results < 1 then max_results = 1 end

        local result, err = tavily_search(query, max_results)
        if not result then
            return {
                content = {{type = "text", text = "Error: " .. (err or "unknown")}},
                isError = true,
            }
        end

        local output = {}
        if result.answer then
            output[#output + 1] = "Answer: " .. result.answer
            output[#output + 1] = ""
        end
        if result.results then
            output[#output + 1] = "Results:"
            for i, r in ipairs(result.results) do
                output[#output + 1] = i .. ". " .. (r.title or "No title")
                output[#output + 1] = "   URL: " .. (r.url or "")
                if r.content then
                    local snippet = r.content:sub(1, 200)
                    if #r.content > 200 then snippet = snippet .. "..." end
                    output[#output + 1] = "   " .. snippet
                end
                output[#output + 1] = ""
            end
        end

        return {
            content = {{type = "text", text = table.concat(output, "\n")}},
        }
    end

    return {
        content = {{type = "text", text = "Unknown tool: " .. name}},
        isError = true,
    }
end

local function handle_mcp_request(msg)
    local method = msg.method
    local params = msg.params or {}
    local id = msg.id

    if method == "initialize" then
        return jsonrpc_response(id, {
            protocolVersion = MCP_VERSION,
            capabilities = {
                tools = {},
            },
            serverInfo = {
                name = SERVER_NAME,
                version = SERVER_VERSION,
            },
        })
    elseif method == "notifications/initialized" then
        return nil
    elseif method == "tools/list" then
        return jsonrpc_response(id, {
            tools = tools,
        })
    elseif method == "tools/call" then
        local tool_name = params.name
        local arguments = params.arguments or {}
        local result = handle_tool_call(tool_name, arguments)
        return jsonrpc_response(id, result)
    elseif method == "ping" then
        return jsonrpc_response(id, {})
    else
        return jsonrpc_error(id, -32601, "Method not found: " .. (method or "nil"))
    end
end

io.stderr:write("[mcp-stdio] " .. SERVER_NAME .. " v" .. SERVER_VERSION .. " started\n")
io.stderr:write("[mcp-stdio] Waiting for JSON-RPC messages on stdin...\n")

for line in io.stdin:lines() do
    if line ~= "" then
        local ok, msg = pcall(json_decode, line)
        if ok and msg then
            io.stderr:write("[mcp-stdio] <- " .. (msg.method or "response") .. "\n")
            local response = handle_mcp_request(msg)
            if response then
                io.stdout:write(response .. "\n")
                io.stdout:flush()
                io.stderr:write("[mcp-stdio] -> response\n")
            end
        else
            io.stderr:write("[mcp-stdio] Invalid JSON: " .. line:sub(1, 50) .. "\n")
            local err_response = jsonrpc_error(nil, -32700, "Parse error")
            io.stdout:write(err_response .. "\n")
            io.stdout:flush()
        end
    end
end

io.stderr:write("[mcp-stdio] stdin closed, exiting\n")
