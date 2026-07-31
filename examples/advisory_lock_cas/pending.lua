-- Pending-table: correlate peer REPLYs to waiting coroutines by msg_id.
-- One dispatcher coroutine owns udp.recv(peer_sock); workers register a
-- waiter, send their request, then poll via wait(). Unknown or expired
-- msg_ids are reported to the caller (which logs the drop).
--
-- wait() must be called inside a lunet coroutine (uses lunet.sleep).

local pending = {}

local POLL_MS = 5

function pending.new()
    local waiters = {}
    local p = {}

    function p.register(msg_id)
        local w = { done = false, reply = nil, id = msg_id }
        waiters[msg_id] = w
        return w
    end

    -- Returns true if a waiter consumed the reply, false if it is a drop
    -- (unknown or expired msg_id).
    function p.deliver(msg_id, reply)
        local w = waiters[msg_id]
        if not w then return false end
        waiters[msg_id] = nil
        w.done = true
        w.reply = reply
        return true
    end

    -- Returns (reply, false) on delivery, (nil, true) on timeout. On
    -- timeout the waiter is expired: a late reply becomes a drop.
    function p.wait(w, timeout_ms)
        local lunet = require("lunet")
        local waited = 0
        while not w.done and waited < timeout_ms do
            lunet.sleep(POLL_MS)
            waited = waited + POLL_MS
        end
        if w.done then
            return w.reply, false
        end
        waiters[w.id] = nil
        return nil, true
    end

    return p
end

return pending
