io.stdout:setvbuf('no')
local lunet = require("lunet")

local socket = require("lunet.socket")

package.path = package.path .. ";/Users/Shared/lunet/?.lua"

local config = require("app.config")
local http = require("app.lib.http")
local json = require("app.lib.json")
local db = require("app.lib.db")
local auth = require("app.lib.auth")

db.set_config(config.db)
-- db.init() moved to inside lunet.spawn as it requires a coroutine
auth.set_config(config)

local handlers = {
    users = require("app.handlers.users"),
    profiles = require("app.handlers.profiles"),
    articles = require("app.handlers.articles"),
    comments = require("app.handlers.comments"),
    tags = require("app.handlers.tags"),
}

local routes = {
    {method = "POST", pattern = "/api/users/login", handler = handlers.users.login},
    {method = "POST", pattern = "/api/users", handler = handlers.users.register},
    {method = "GET", pattern = "/api/user", handler = handlers.users.current},
    {method = "PUT", pattern = "/api/user", handler = handlers.users.update},

    {method = "GET", pattern = "/api/profiles/:username", handler = handlers.profiles.get},
    {method = "POST", pattern = "/api/profiles/:username/follow", handler = handlers.profiles.follow},
    {method = "DELETE", pattern = "/api/profiles/:username/follow", handler = handlers.profiles.unfollow},

    {method = "GET", pattern = "/api/articles/feed", handler = handlers.articles.feed},
    {method = "GET", pattern = "/api/articles", handler = handlers.articles.list},
    {method = "GET", pattern = "/api/articles/:slug", handler = handlers.articles.get},
    {method = "POST", pattern = "/api/articles", handler = handlers.articles.create},
    {method = "PUT", pattern = "/api/articles/:slug", handler = handlers.articles.update},
    {method = "DELETE", pattern = "/api/articles/:slug", handler = handlers.articles.delete},
    {method = "POST", pattern = "/api/articles/:slug/favorite", handler = handlers.articles.favorite},
    {method = "DELETE", pattern = "/api/articles/:slug/favorite", handler = handlers.articles.unfavorite},

    {method = "GET", pattern = "/api/articles/:slug/comments", handler = handlers.comments.list},
    {method = "POST", pattern = "/api/articles/:slug/comments", handler = handlers.comments.create},
    {method = "DELETE", pattern = "/api/articles/:slug/comments/:id", handler = handlers.comments.delete},

    {method = "GET", pattern = "/api/tags", handler = handlers.tags.list},
}

local function match_route(method, path)
    for _, route in ipairs(routes) do
        if route.method == method then
            local pattern_parts = {}
            for part in route.pattern:gmatch("[^/]+") do
                pattern_parts[#pattern_parts + 1] = part
            end

            local path_parts = {}
            for part in path:gmatch("[^/]+") do
                path_parts[#path_parts + 1] = part
            end

            if #pattern_parts == #path_parts then
                local params = {}
                local match = true
                for i, pp in ipairs(pattern_parts) do
                    if pp:sub(1, 1) == ":" then
                        params[pp:sub(2)] = path_parts[i]
                    elseif pp ~= path_parts[i] then
                        match = false
                        break
                    end
                end
                if match then
                    return route.handler, params
                end
            end
        end
    end
    return nil, nil
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function get_mime_type(path)
    if path:match("%.html$") then return "text/html" end
    if path:match("%.css$") then return "text/css" end
    if path:match("%.js$") then return "application/javascript" end
    return "application/octet-stream"
end

local function handle_request(request)
    if request.method == "OPTIONS" then
        return http.options_response()
    end

    auth.middleware(request)

    local handler, params = match_route(request.method, request.path)
    if not handler then
        -- Static file / SPA fallback
        if request.method == "GET" then
            local file_path = "www" .. request.path
            if request.path == "/" then
                file_path = "www/index.html"
            end
            
            -- Basic directory traversal protection
            if file_path:find("%.%.") then
                return http.error_response(403, {body = {"Forbidden"}})
            end

            local content = read_file(file_path)
            if not content and not request.path:find("^/api/") then
                 -- SPA fallback for non-API routes
                 content = read_file("www/index.html")
                 file_path = "www/index.html"
            end

            if content then
                return http.response(200, {
                    ["Content-Type"] = get_mime_type(file_path),
                    ["Connection"] = "close"
                }, content)
            end
        end
        return http.error_response(404, {body = {"Not found"}})
    end

    request.params = params or {}

    if request.body and request.headers and
       request.headers["content-type"] and
       request.headers["content-type"]:find("application/json") then
        local ok, parsed = pcall(json.decode, request.body)
        if ok then
            request.json = parsed
        end
    end

    local ok, response = pcall(handler, request)
    if not ok then
        print("Handler error: " .. tostring(response))
        return http.error_response(500, {body = {"Internal server error"}})
    end

    if type(response) ~= "string" then
        print("Handler returned non-string response: " .. type(response))
        return http.error_response(500, {body = {"Internal server error"}})
    end

    local cors = http.cors_headers()
    for k, v in pairs(cors) do
        response = response:gsub("\r\n\r\n", "\r\n" .. k .. ": " .. v .. "\r\n\r\n", 1)
    end

    return response
end

local function handle_client(client)
    local function task()
        local data = socket.read(client)
        if not data then
            return
        end

        local request, parse_err = http.parse_request(data)
        if not request then
            local response = http.error_response(400, {body = {parse_err or "Bad request"}})
            socket.write(client, response)
            return
        end

        local response = handle_request(request)
        socket.write(client, response)
    end

    local ok, err = pcall(task)
    socket.close(client)
    
    if not ok then
        print("Client handler error: " .. tostring(err))
    end
end

lunet.spawn(function()
    local db_init_ok, db_init_err = db.init()
    if not db_init_ok then
        print("Database initialization failed: " .. (db_init_err or "unknown error"))
        os.exit(1)
    end

    local listener, err = socket.listen("tcp", config.server.host, config.server.port)
    if not listener then
        print("Failed to listen: " .. (err or "unknown error"))
        os.exit(1)
    end

    print("Conduit API server listening on http://" .. config.server.host .. ":" .. config.server.port)

    while true do
        local client = socket.accept(listener)
        if client then
            lunet.spawn(function()
                handle_client(client)
            end)
        end
    end
end)
