--[[
  Smoke test for httpc HEAD requests:

  A HEAD response carries Content-Length with no body. The client must
  return the response (status + headers, empty body) as soon as the header
  block arrives, not block waiting for a body until the request timeout.

  A raw loopback server answers HEAD with Content-Length: 100 and no body
  (connection stays open), and GET with a 100-byte body. The wire method is
  recorded per request line so a fix that silently downgrades HEAD to GET
  cannot pass.

  Exits 0 on success, 1 on failure.
]]

local lunet = require("lunet")
local socket = require("lunet.socket")
local httpc = require("lunet.httpc")

local PORT = 18775
local BODY_LEN = 100
local TIMEOUT_MS = 3000

local failures = 0
local served = {} -- request-line methods seen on the wire, in order

local function fail(msg)
    failures = failures + 1
    io.stderr:write("[HTTPC_HEAD_SMOKE] FAIL: " .. msg .. "\n")
end

local function finish()
    if failures == 0 then
        print("[HTTPC_HEAD_SMOKE] ok")
        _G.__lunet_exit_code = 0
        os.exit(0)
    end
    _G.__lunet_exit_code = 1
    os.exit(1)
end

local function header_value(resp, name_lower)
    for _, h in ipairs(resp.headers or {}) do
        if type(h) == "table" and type(h.name) == "string" and h.name:lower() == name_lower then
            return h.value
        end
    end
    return nil
end

lunet.spawn(function()
    -- Watchdog: whatever fails on whatever platform, the process must
    -- terminate. A client-side error before the finish path would
    -- otherwise leave the listener coroutines holding the loop open and
    -- the smoke would hang a CI runner to its job timeout.
    lunet.spawn(function()
        lunet.sleep(15000)
        fail("watchdog timeout - client never completed (15s)")
        _G.__lunet_exit_code = 1
        os.exit(1)
    end)

    local listener, lerr = socket.listen("tcp", "127.0.0.1", PORT)
    if not listener then
        fail("listen failed: " .. tostring(lerr))
        _G.__lunet_exit_code = 1
        os.exit(1)
        return
    end

    local function serve_conn(conn)
        local buf = ""
        while true do
            -- A request head is the request line plus headers up to the
            -- blank line; only the FIRST line is a request line. Header
            -- lines are consumed, never dispatched on.
            local s, e = buf:find("\r\n\r\n", 1, true)
            if not s then
                local data = socket.read(conn)
                if not data then
                    break -- EOF: client closed the connection
                end
                buf = buf .. data
            else
                local head = buf:sub(1, s - 1)
                buf = buf:sub(e + 1)
                local req_line = head:match("^[^\r\n]*")
                local method = req_line and req_line:match("^(%S+)%s")
                if method then
                    served[#served + 1] = method
                    if method == "HEAD" then
                        -- Content-Length advertises a body size, but HEAD
                        -- sends none; the connection stays open.
                        socket.write(conn,
                            "HTTP/1.1 200 OK\r\n" ..
                            "Content-Length: " .. BODY_LEN .. "\r\n" ..
                            "Connection: keep-alive\r\n" ..
                            "\r\n")
                    else
                        socket.write(conn,
                            "HTTP/1.1 200 OK\r\n" ..
                            "Content-Length: " .. BODY_LEN .. "\r\n" ..
                            "Connection: keep-alive\r\n" ..
                            "\r\n" .. string.rep("x", BODY_LEN))
                    end
                end
            end
        end
        socket.close(conn)
    end

    -- Accept loop: one connection per request (fresh curl easy handle each
    -- time), kept general for HTTP keep-alive clients.
    lunet.spawn(function()
        while true do
            local conn = socket.accept(listener)
            if not conn then
                break
            end
            lunet.spawn(function()
                serve_conn(conn)
            end)
        end
    end)

    -- Client side: HEAD first (the case that hangs pre-fix), then GET as
    -- the contrast proving the server answers normally. pcall-wrapped so
    -- a client-side error reports its message instead of dying silently
    -- (the watchdog would still terminate the process).
    lunet.spawn(function()
        local ok, perr = pcall(function()
            local url = "http://127.0.0.1:" .. PORT .. "/"

            local resp, err = httpc.request({
                url = url,
                method = "HEAD",
                timeout_ms = TIMEOUT_MS,
            })
            if not resp then
                fail("HEAD returned no response (expected immediate headers): " .. tostring(err))
            else
                if resp.status ~= 200 then
                    fail("HEAD status expected 200, got " .. tostring(resp.status))
                end
                local body_len = resp.body and #resp.body or 0
                if body_len ~= 0 then
                    fail("HEAD body expected empty, got " .. body_len .. " bytes")
                end
                local cl = header_value(resp, "content-length")
                if cl ~= tostring(BODY_LEN) then
                    fail("HEAD Content-Length header expected " .. BODY_LEN .. ", got " .. tostring(cl))
                end
            end

            local resp2, err2 = httpc.request({
                url = url,
                method = "GET",
                timeout_ms = TIMEOUT_MS,
            })
            if not resp2 then
                fail("GET returned no response: " .. tostring(err2))
            else
                if resp2.status ~= 200 then
                    fail("GET status expected 200, got " .. tostring(resp2.status))
                end
                local n = resp2.body and #resp2.body or 0
                if n ~= BODY_LEN then
                    fail("GET body expected " .. BODY_LEN .. " bytes, got " .. n)
                end
            end
        end)
        if not ok then
            fail("client error: " .. tostring(perr))
        end

        -- The wire must have carried a HEAD request line (and the GET):
        -- a fix that downgrades HEAD to GET cannot pass this.
        local saw_head, saw_get = false, false
        for _, m in ipairs(served) do
            if m == "HEAD" then
                saw_head = true
            elseif m == "GET" then
                saw_get = true
            end
        end
        if not saw_head then
            fail("server never saw a HEAD request line; methods seen: " .. table.concat(served, ","))
        end
        if not saw_get then
            fail("server never saw a GET request line; methods seen: " .. table.concat(served, ","))
        end

        socket.close(listener)
        finish()
    end)
end)
