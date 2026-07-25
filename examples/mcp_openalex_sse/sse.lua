-- SSE (Server-Sent Events) session store for the MCP transport.
-- One coroutine owns each SSE socket (lunet forbids concurrent writes to
-- the same socket); POST handler coroutines only append to the queue.

local lunet = require("lunet")
local socket = require("lunet.socket")

local M = {}

local sessions = {}

local FLUSH_INTERVAL_S = 0.005
local HEARTBEAT_AFTER_S = 15

function M.create(conn)
    local id = string.format("%08x-%04x-%04x-%04x-%012x",
        math.random(0, 0xffffffff), math.random(0, 0xffff), math.random(0, 0xffff),
        math.random(0, 0xffff), math.random(0, 0xffffffffffff))
    local session = { id = id, conn = conn, queue = {}, closed = false }
    sessions[id] = session
    return session
end

function M.find(id)
    return id and sessions[id]
end

-- Queues a JSON-RPC payload for delivery on the session's SSE stream.
function M.push(session, payload)
    session.queue[#session.queue + 1] = "event: message\ndata: " .. payload .. "\n\n"
end

-- socket.write resumes with nil on success, or an error string on failure.
local function send(session, chunk)
    if session.closed then return false end
    local werr = socket.write(session.conn, chunk)
    if werr then
        session.closed = true
        return false
    end
    return true
end

-- Runs the SSE stream for the session: emits the endpoint event, then
-- flushes queued events with a comment heartbeat. Blocks until the client
-- disconnects, then unregisters the session.
function M.pump(session, endpoint_uri)
    if not send(session, "event: endpoint\ndata: " .. endpoint_uri .. "\n\n") then
        sessions[session.id] = nil
        return
    end
    local last_write = os.clock()
    while not session.closed do
        if #session.queue > 0 then
            local chunk = table.concat(session.queue)
            session.queue = {}
            if not send(session, chunk) then break end
            last_write = os.clock()
        elseif os.clock() - last_write > HEARTBEAT_AFTER_S then
            if not send(session, ": ka\n\n") then break end
            last_write = os.clock()
        else
            lunet.sleep(FLUSH_INTERVAL_S)
        end
    end
    sessions[session.id] = nil
end

return M
