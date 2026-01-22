local lunet = require("lunet")
local socket = require("lunet.socket")

local function json_encode(t)
    if type(t) ~= "table" then
        if type(t) == "string" then return '"' .. t .. '"' end
        if type(t) == "number" then return tostring(t) end
        if type(t) == "boolean" then return t and "true" or "false" end
        return "null"
    end
    local parts = {}
    local is_array = (#t > 0)
    if is_array then
        for _, v in ipairs(t) do
            parts[#parts + 1] = json_encode(v)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    else
        for k, v in pairs(t) do
            parts[#parts + 1] = '"' .. k .. '":' .. json_encode(v)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
end

local routes = {
    { method = "GET", pattern = "/", handler = function(req, params)
        return { message = "Welcome to Lunet routing example!" }
    end },
    { method = "GET", pattern = "/users", handler = function(req, params)
        return { users = { { id = 1, name = "Alice" }, { id = 2, name = "Bob" } } }
    end },
    { method = "GET", pattern = "/users/:id", handler = function(req, params)
        return { user = { id = tonumber(params.id), name = "User " .. params.id } }
    end },
    { method = "GET", pattern = "/articles/:slug", handler = function(req, params)
        return { article = { slug = params.slug, title = "Article: " .. params.slug } }
    end },
    { method = "GET", pattern = "/articles/:slug/comments/:id", handler = function(req, params)
        return { comment = { article_slug = params.slug, comment_id = params.id } }
    end },
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
                local matched = true
                for i, pp in ipairs(pattern_parts) do
                    if pp:sub(1, 1) == ":" then
                        params[pp:sub(2)] = path_parts[i]
                    elseif pp ~= path_parts[i] then
                        matched = false
                        break
                    end
                end
                if matched then
                    return route.handler, params
                end
            end
        end
    end
    return nil, nil
end

local function parse_request(data)
    local first_line = data:match("^([^\r\n]+)")
    if not first_line then return nil end
    local method, path = first_line:match("^(%w+)%s+([^%s]+)")
    return { method = method, path = path }
end

local function handle_request(client)
    local data, err = socket.read(client)
    if not data then
        socket.close(client)
        return
    end

    local request = parse_request(data)
    if not request then
        socket.close(client)
        return
    end

    local handler, params = match_route(request.method, request.path)
    local response_body
    local status = "200 OK"

    if handler then
        local result = handler(request, params)
        response_body = json_encode(result)
    else
        status = "404 Not Found"
        response_body = json_encode({ error = "Not found", path = request.path })
    end

    local response = "HTTP/1.1 " .. status .. "\r\n" ..
        "Content-Type: application/json\r\n" ..
        "Content-Length: " .. #response_body .. "\r\n\r\n" ..
        response_body

    socket.write(client, response)
    socket.close(client)
end

lunet.spawn(function()
    local listener, err = socket.listen("tcp", "127.0.0.1", 8080)
    if not listener then
        print("Failed to listen: " .. (err or "unknown"))
        return
    end

    print("Routing example server listening on http://127.0.0.1:8080")
    print("Try these URLs:")
    print("  curl http://127.0.0.1:8080/")
    print("  curl http://127.0.0.1:8080/users")
    print("  curl http://127.0.0.1:8080/users/42")
    print("  curl http://127.0.0.1:8080/articles/hello-world")
    print("  curl http://127.0.0.1:8080/articles/my-post/comments/5")

    while true do
        local client, cerr = socket.accept(listener)
        if client then
            lunet.spawn(function()
                handle_request(client)
            end)
        end
    end
end)
