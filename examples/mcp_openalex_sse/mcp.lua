-- Minimal MCP (Model Context Protocol) JSON-RPC surface: initialize,
-- notifications, ping, tools/list, tools/call. Transport (Streamable HTTP)
-- lives in main.lua.

local jsonic = require("lunet.jsonic")

local M = {}

local SUPPORTED_PROTOCOL_VERSIONS = { "2025-03-26", "2024-11-05" }
local SERVER_NAME = "lunet-mcp-openalex"
local SERVER_VERSION = "0.1.0"

-- dkjson encodes empty tables as []; the MCP spec wants JSON objects
-- for empty results (ping) and capabilities.tools.
local EMPTY_OBJECT = setmetatable({}, { __jsontype = "object" })

local TOOLS = {
    {
        name = "openalex_search_works",
        description = "Search OpenAlex scholarly works (papers, preprints) by " ..
            "free-text query. Returns titles, authors, citation counts and " ..
            "OpenAlex IDs. Costs about $0.001 per call against the free $1/day budget.",
        inputSchema = {
            type = "object",
            properties = {
                query = { type = "string", description = "Free-text search, e.g. 'event sourcing'" },
                limit = { type = "integer", description = "Max results, 1-25 (default 5)" },
            },
            required = { "query" },
        },
    },
    {
        name = "openalex_get_work",
        description = "Fetch one OpenAlex work by OpenAlex ID (W...), DOI, or URL. " ..
            "Free endpoint. Returns metadata and the reconstructed abstract.",
        inputSchema = {
            type = "object",
            properties = {
                id = { type = "string", description = "OpenAlex ID (W...), DOI, or URL" },
            },
            required = { "id" },
        },
    },
    {
        name = "openalex_search_authors",
        description = "Search OpenAlex authors by name. Returns affiliation, " ..
            "works count, citation count and OpenAlex IDs.",
        inputSchema = {
            type = "object",
            properties = {
                query = { type = "string", description = "Author name to search for" },
                limit = { type = "integer", description = "Max results, 1-25 (default 5)" },
            },
            required = { "query" },
        },
    },
}

local function tool_error(message)
    return {
        content = { { type = "text", text = message } },
        isError = true,
    }
end

local function tool_text(message)
    return {
        content = { { type = "text", text = message } },
        isError = false,
    }
end

-- Transport-level rejection bodies (parse errors, session errors).
function M.encode_error(id, code, message)
    return jsonic.encode({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

-- Creates a dispatcher bound to an OpenAlex client.
function M.new(client)
    local function call_tool(name, args)
        args = args or {}
        if name == "openalex_search_works" then
            local text, err = client.search_works(args.query, args.limit)
            if not text then return tool_error(err) end
            return tool_text(text)
        elseif name == "openalex_get_work" then
            local text, err = client.get_work(args.id)
            if not text then return tool_error(err) end
            return tool_text(text)
        elseif name == "openalex_search_authors" then
            local text, err = client.search_authors(args.query, args.limit)
            if not text then return tool_error(err) end
            return tool_text(text)
        end
        return tool_error("unknown tool: " .. tostring(name))
    end

    local function encode(response)
        return jsonic.encode(response)
    end

    -- Handles one parsed JSON-RPC message. Returns a response table to write
    -- back, or nil for notifications and client responses (no reply).
    local function dispatch(message)
        if type(message) ~= "table" or message == jsonic.null then
            return { jsonrpc = "2.0", id = nil,
                error = { code = -32600, message = "Invalid Request" } }
        end
        local id = message.id
        local method = message.method

        if method == nil and (message.result ~= nil or message.error ~= nil) then
            return nil -- a client response: this server sends no requests
        end

        if method == "notifications/initialized" or method == "notifications/cancelled" then
            return nil
        end

        if method == "initialize" then
            local requested = (message.params or {}).protocolVersion
            local negotiated = SUPPORTED_PROTOCOL_VERSIONS[2]
            for _, v in ipairs(SUPPORTED_PROTOCOL_VERSIONS) do
                if requested == v then
                    negotiated = v
                    break
                end
            end
            return {
                jsonrpc = "2.0", id = id,
                result = {
                    protocolVersion = negotiated,
                    capabilities = { tools = EMPTY_OBJECT },
                    serverInfo = { name = SERVER_NAME, version = SERVER_VERSION },
                },
            }
        elseif method == "ping" then
            return { jsonrpc = "2.0", id = id, result = EMPTY_OBJECT }
        elseif method == "tools/list" then
            return { jsonrpc = "2.0", id = id, result = { tools = TOOLS } }
        elseif method == "tools/call" then
            local params = message.params or {}
            if type(params.name) ~= "string" then
                return { jsonrpc = "2.0", id = id,
                    error = { code = -32602, message = "tools/call requires params.name" } }
            end
            return { jsonrpc = "2.0", id = id,
                result = call_tool(params.name, params.arguments) }
        end

        if id == nil then
            return nil -- unknown notification: ignore
        end
        return { jsonrpc = "2.0", id = id,
            error = { code = -32601, message = "Method not found: " .. tostring(method) } }
    end

    return { dispatch = dispatch, encode = encode }
end

return M
