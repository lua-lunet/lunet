-- Message codec for advisory lock CAS wire protocol
-- Pure Lua, no external dependencies

local codec = {}

local function is_hex8(s)
    return type(s) == "string" and #s == 8 and s:match("^[0-9a-fA-F]+$") ~= nil
end

local function is_hex16(s)
    return type(s) == "string" and #s == 16 and s:match("^[0-9a-fA-F]+$") ~= nil
end

local function parse_get(rest)
    local lock_str, msg_id = rest:match("^/locks/(%d+) (%S+)$")
    if not lock_str then return nil, "malformed GET" end
    local lock_id = tonumber(lock_str)
    if not is_hex8(msg_id) then return nil, "invalid msg_id" end
    return { type = "GET", lock_id = lock_id, msg_id = msg_id }
end

local function parse_set(rest)
    local lock_str, token_str, holder_str, msg_id = rest:match("^/locks/(%d+) (%S+) (%d+) (%S+)$")
    if not lock_str then return nil, "malformed SET" end
    local lock_id = tonumber(lock_str)
    if not is_hex16(token_str) then return nil, "invalid token" end
    local token = tonumber(token_str, 16)
    local holder = tonumber(holder_str)
    if not is_hex8(msg_id) then return nil, "invalid msg_id" end
    return { type = "SET", lock_id = lock_id, token = token, holder = holder, msg_id = msg_id }
end

local function parse_reply(rest)
    local msg_id, status, holder_str, token_str = rest:match("^(%S+) (%S+) (%S+) (%S+)$")
    if msg_id then
        if not is_hex8(msg_id) then return nil, "invalid msg_id" end
        if status ~= "OK" and status ~= "CONFLICT" then return nil, "invalid status" end
        local holder = tonumber(holder_str)
        if not holder then return nil, "invalid holder" end
        if not is_hex16(token_str) then return nil, "invalid token" end
        local token = tonumber(token_str, 16)
        return { type = "REPLY", msg_id = msg_id, status = status, holder = holder, token = token }
    end
    local msg_id2, status2 = rest:match("^(%S+) (%S+)$")
    if msg_id2 then
        if not is_hex8(msg_id2) then return nil, "invalid msg_id" end
        if status2 ~= "NOT_FOUND" then return nil, "invalid status" end
        return { type = "REPLY", msg_id = msg_id2, status = status2 }
    end
    return nil, "malformed REPLY"
end

function codec.parse(raw)
    if type(raw) ~= "string" then return nil, "input must be a string" end
    local s = raw:match("^(.-)%s*$")
    if not s or s == "" then return nil, "empty message" end

    local cmd, rest = s:match("^(%S+) (.+)$")
    if not cmd then return nil, "malformed message" end

    if cmd == "GET" then
        return parse_get(rest)
    elseif cmd == "SET" then
        return parse_set(rest)
    elseif cmd == "PEER" then
        local sub, subrest = rest:match("^(%S+) (.+)$")
        if not sub then return nil, "malformed PEER message" end
        if sub == "GET" then
            local msg = parse_get(subrest)
            if msg then msg.type = "PEER_GET" end
            return msg
        elseif sub == "SET" then
            local msg = parse_set(subrest)
            if msg then msg.type = "PEER_SET" end
            return msg
        else
            return nil, "unknown PEER subcommand"
        end
    elseif cmd == "REPLY" then
        return parse_reply(rest)
    else
        return nil, "unknown command"
    end
end

function codec.format_reply(msg_id, status, holder, token)
    if status == "NOT_FOUND" then
        return string.format("REPLY %s NOT_FOUND", msg_id)
    elseif status == "OK" or status == "CONFLICT" then
        return string.format("REPLY %s %s %d %016x", msg_id, status, holder, token)
    else
        error("unknown status: " .. tostring(status))
    end
end

function codec.format_peer(cmd, lock_id, token, holder, msg_id)
    if cmd == "PEER_GET" then
        return string.format("PEER GET /locks/%d %s", lock_id, msg_id)
    elseif cmd == "PEER_SET" then
        return string.format("PEER SET /locks/%d %016x %d %s", lock_id, token, holder, msg_id)
    else
        error("unknown peer command: " .. tostring(cmd))
    end
end

return codec
