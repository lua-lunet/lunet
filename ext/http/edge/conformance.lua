-- Conformance suite for the edge examples (ext/http/edge/Dockerfile.*).
-- Runs on the lunet runtime and drives the edge from outside the container.
--
-- Usage (from a container on the same docker network as the edge):
--   lunet-run conformance.lua <edge-host> <drip-port>
--
-- Exit status 0 = all checks passed; nonzero = at least one failure.

local lunet = require("lunet")
local httpc = require("lunet.httpc")
local socket = require("lunet.socket")

local target = arg[1] or "http://edge"
local drip_port = tonumber(arg[2] or "80")
-- The drip test uses raw sockets, and lunet's socket.connect takes an
-- address, not a name (no resolver): the driver passes the edge
-- container's IP as the third argument.
local drip_host = arg[3] or target:match("^https?://([^/:]+)")

lunet.spawn(function()
    local pass, fail = 0, 0
    local function check(name, ok, detail)
        if ok then
            pass = pass + 1
            print("PASS " .. name)
        else
            fail = fail + 1
            print("FAIL " .. name .. (detail and (" - " .. detail) or ""))
        end
    end

    local function request(method, path, headers, body)
        return httpc.request({
            url = target .. path,
            method = method,
            headers = headers,
            body = body,
            timeout_ms = 15000,
        })
    end

    -- 1. Happy paths: the app's endpoints answer through the edge unchanged.

    local suffix = tostring(os.time()) .. tostring(math.random(100000, 999999))
    local email = "edge-" .. suffix .. "@example.com"
    local user_body = '{"user":{"email":"' .. email
        .. '","password":"password123","username":"edge' .. suffix .. '"}}'

    local resp, err = request("GET", "/health")
    check("health through the edge answers 200",
        resp ~= nil and resp.status == 200,
        err or ("status " .. tostring(resp and resp.status)))

    resp, err = request("POST", "/api/users",
        {["Content-Type"] = "application/json"}, user_body)
    local token
    local reg_ok = resp ~= nil and resp.status == 201
    check("register through the edge answers 201", reg_ok,
        err or ("status " .. tostring(resp and resp.status)))
    if reg_ok then
        token = resp.body:match('"token"%s*:%s*"([^"]+)"')
    end

    if token then
        resp, err = request("GET", "/api/user", {Authorization = "Token " .. token})
        check("authenticated fetch through the edge answers 200",
            resp ~= nil and resp.status == 200,
            err or ("status " .. tostring(resp and resp.status)))

        local art = '{"article":{"title":"Edge conformance","description":"d",'
            .. '"body":"b","tagList":["edge"]}}'
        resp, err = request("POST", "/api/articles",
            {["Content-Type"] = "application/json", Authorization = "Token " .. token},
            art)
        check("article creation through the edge answers 201",
            resp ~= nil and resp.status == 201,
            err or ("status " .. tostring(resp and resp.status)))
    end

    resp, err = request("GET", "/api/articles")
    check("article list through the edge answers 200",
        resp ~= nil and resp.status == 200,
        err or ("status " .. tostring(resp and resp.status)))

    -- 2. Oversize body: the edge refuses it (413) and never forwards it.

    local big = string.rep("x", 2 * 1024 * 1024) -- 2 MiB, past the 1 MiB cap
    resp, err = request("POST", "/api/articles",
        {["Content-Type"] = "application/json"}, big)
    check("oversize body answered by the edge (413 or connection refused)",
        (resp ~= nil and resp.status == 413) or err ~= nil,
        err or ("status " .. tostring(resp and resp.status)))

    -- 3. Oversize header section: refused by the edge (400, 414 or 431
    -- depending on the product).

    local pads = {}
    for i = 1, 40 do
        pads["X-Pad-" .. tostring(i)] = string.rep("k", 1024) -- 40 KiB total
    end
    resp, err = request("GET", "/health", pads)
    check("oversize header section refused by the edge",
        (resp ~= nil and (resp.status == 400 or resp.status == 414
            or resp.status == 431)) or err ~= nil,
        err or ("status " .. tostring(resp and resp.status)))

    -- 4. Drip-feed: fragments with pauses; the edge must cut the connection
    -- within its read timeout and never complete the request.
    local drip_ok, drip_err = pcall(function()
        local sock, cerr = socket.connect(drip_host, drip_port)
        if not sock then
            error("connect failed: " .. tostring(cerr))
        end
        -- Half a request line, then dribble fragments with pauses. A
        -- conforming edge times out and closes; it must never complete
        -- the request.
        socket.write(sock, "GET /health HTTP/1.1\r\nHost: edge\r\n")
        for _ = 1, 6 do
            socket.write(sock, "X-Pad: " .. string.rep("d", 32) .. "\r\n")
            lunet.sleep(1000) -- 1s between fragments; edge timeout is 10s
        end
        -- One read attempt: the connection is closed (nil + error), or the
        -- edge answered 408. A forwarded 200 is a failure.
        local data = socket.read(sock)
        socket.close(sock)
        if data and data:find("^HTTP/1 200") then
            error("dribbled request was completed by the edge (200)")
        end
        -- EOF or a 408 response both conform.
    end)
    check("drip-fed request cut off by the edge", drip_ok, drip_err)

    print(string.format("conformance: %d passed, %d failed", pass, fail))
    os.exit(fail == 0 and 0 or 1)
end)
