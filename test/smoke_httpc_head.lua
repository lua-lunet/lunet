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
    io.stderr:write("[HTTPC_HEAD_SMOKE] stage: listening\n")

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
                    io.stderr:write("[HTTPC_HEAD_SMOKE] stage: server saw " .. method .. "\n")
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
                    io.stderr:write("[HTTPC_HEAD_SMOKE] stage: server wrote " .. method .. " response\n")
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
            -- Probe 0: lunet.fs async read — the SAME uv threadpool +
            -- completion machinery httpc rides on (uv_fs_read -> worker ->
            -- completion callback -> lunet_co_resume), minus curl. Runs
            -- FIRST so its datapoint lands even if the httpc probes hang.
            -- If this hangs on Windows too, the fault is threadpool-wide;
            -- if it completes, the fault is httpc/curl-side.
            local script = debug.getinfo(1, "S").source
            local dir = script:match("^@(.+)[/\\][^/\\]+$")
            local tmp = os.tmpname()
            local f = io.open(tmp, "wb")
            f:write(string.rep("y", BODY_LEN))
            f:close()
            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: sending fs probe\n")
            local fs = require("lunet.fs")
            local fok, ffd = pcall(fs.open, tmp, "r")
            if fok and ffd then
                local rdata, rerr = fs.read(ffd, BODY_LEN)
                io.stderr:write("[HTTPC_HEAD_SMOKE] stage: fs probe returned len="
                    .. (rdata and #rdata or "-") .. " err=" .. tostring(rerr) .. "\n")
                fs.close(ffd)
            else
                io.stderr:write("[HTTPC_HEAD_SMOKE] stage: fs probe open failed: " .. tostring(ffd) .. "\n")
            end

            -- Probe 1: file:// GET — exercises the whole httpc pipeline
            -- (worker thread, curl, completion resume) with no sockets.
            -- A hang here means the uv_worker→resume path; a pass here
            -- with the loopback probes hanging means the TCP path.
            local path = tmp
            if path:sub(1, 1) ~= "/" then
                path = path:gsub("\\", "/")
                path = "/" .. path
            end
            local file_url = "file://" .. path
            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: sending file:// GET (" .. file_url .. ")\n")
            local fres, ferr = httpc.request({ url = file_url, timeout_ms = 2000 })
            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: file:// GET returned status="
                .. (fres and fres.status or "nil") .. " body=" .. (fres and fres.body and #fres.body or "-")
                .. " err=" .. tostring(ferr) .. "\n")

            local url = "http://127.0.0.1:" .. PORT .. "/"

            -- Probe 1: plain loopback GET before the HEAD case.
            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: sending loopback GET probe\n")
            local gres, gerr = httpc.request({ url = url, timeout_ms = 2000 })
            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: loopback GET probe returned status="
                .. (gres and gres.status or "nil") .. " body=" .. (gres and gres.body and #gres.body or "-")
                .. " err=" .. tostring(gerr) .. "\n")

            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: sending HEAD\n")
            local resp, err = httpc.request({
                url = url,
                method = "HEAD",
                timeout_ms = TIMEOUT_MS,
            })
            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: HEAD returned\n")
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

            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: sending GET\n")
            local resp2, err2 = httpc.request({
                url = url,
                method = "GET",
                timeout_ms = TIMEOUT_MS,
            })
            io.stderr:write("[HTTPC_HEAD_SMOKE] stage: GET returned\n")
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
        io.stderr:write("[HTTPC_HEAD_SMOKE] stage: finishing\n")
        finish()
    end)
end)
