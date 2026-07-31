-- Message codec for advisory lock CAS wire protocol
-- Pure Lua, no external dependencies (LuaJIT ULL for exact u64 tokens)
--
-- Statuses:
--   OK, CONFLICT      -> REPLY <msg_id> <status> <holder:u32> <token:hex16>
--   INVALID           -> REPLY <msg_id> INVALID        (semantic reject)
--   UNAVAILABLE       -> REPLY <msg_id> UNAVAILABLE    (peer down/timeout)
-- NOT_FOUND was removed in item15.

local codec = {}

local U32_MAX = 4294967295
local U64_SHIFT = 0x100000000ULL -- 2^32, LuaJIT unsigned 64-bit literal

local function is_hex8(s)
    return type(s) == "string" and #s == 8 and s:match("^[0-9a-fA-F]+$") ~= nil
end

local function is_hex16(s)
    return type(s) == "string" and #s == 16 and s:match("^[0-9a-fA-F]+$") ~= nil
end

-- Decimal u32 only: rejects hex, fractions, negatives, out-of-range.
local function parse_u32(s)
    if type(s) ~= "string" or not s:match("^%d+$") then return nil end
    local n = tonumber(s)
    if not n or n > U32_MAX then return nil end
    return n
end

-- Exact u64: parse two 32-bit halves (tonumber alone loses precision >2^53).
local function parse_u64_hex(s)
    if not is_hex16(s) then return nil end
    local hi = tonumber(s:sub(1, 8), 16)
    local lo = tonumber(s:sub(9, 16), 16)
    return hi * U64_SHIFT + lo
end

-- Format a u64 token (ULL cdata from lock.pack_token, or an exact plain
-- number below 2^53) as 16 lowercase hex chars.
local function fmt_u64(token)
    if type(token) == "number" then
        return string.format("%016x", token)
    end
    local hi = tonumber(token / U64_SHIFT)
    local lo = tonumber(token % U64_SHIFT)
    return string.format("%08x%08x", hi, lo)
end

local function parse_get(rest)
    local lock_str, msg_id = rest:match("^/locks/(%S+) (%S+)$")
    if not lock_str then return nil, "malformed GET" end
    local lock_id = parse_u32(lock_str)
    if not lock_id then return nil, "invalid lock_id" end
    if not is_hex8(msg_id) then return nil, "invalid msg_id" end
    return { type = "GET", lock_id = lock_id, msg_id = msg_id }
end

local function parse_set(rest)
    local lock_str, token_str, holder_str, msg_id =
        rest:match("^/locks/(%S+) (%S+) (%S+) (%S+)$")
    if not lock_str then return nil, "malformed SET" end
    local lock_id = parse_u32(lock_str)
    if not lock_id then return nil, "invalid lock_id" end
    local token = parse_u64_hex(token_str)
    if not token then return nil, "invalid token" end
    local holder = parse_u32(holder_str)
    if not holder then return nil, "invalid holder" end
    if not is_hex8(msg_id) then return nil, "invalid msg_id" end
    return { type = "SET", lock_id = lock_id, token = token, holder = holder, msg_id = msg_id }
end

local STATE_STATUSES = { OK = true, CONFLICT = true }
local BARE_STATUSES = { INVALID = true, UNAVAILABLE = true }

local function parse_reply(rest)
    local msg_id, status, holder_str, token_str = rest:match("^(%S+) (%S+) (%S+) (%S+)$")
    if msg_id then
        if not is_hex8(msg_id) then return nil, "invalid msg_id" end
        if not STATE_STATUSES[status] then return nil, "invalid status" end
        local holder = parse_u32(holder_str)
        if not holder then return nil, "invalid holder" end
        local token = parse_u64_hex(token_str)
        if not token then return nil, "invalid token" end
        return { type = "REPLY", msg_id = msg_id, status = status, holder = holder, token = token }
    end
    local msg_id2, status2 = rest:match("^(%S+) (%S+)$")
    if msg_id2 then
        if not is_hex8(msg_id2) then return nil, "invalid msg_id" end
        if not BARE_STATUSES[status2] then return nil, "invalid status" end
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
    if STATE_STATUSES[status] then
        return "REPLY " .. msg_id .. " " .. status .. " "
            .. string.format("%d", holder) .. " " .. fmt_u64(token)
    elseif BARE_STATUSES[status] then
        return "REPLY " .. msg_id .. " " .. status
    else
        error("unknown status: " .. tostring(status))
    end
end

function codec.format_peer(cmd, lock_id, token, holder, msg_id)
    if cmd == "PEER_GET" then
        return string.format("PEER GET /locks/%d %s", lock_id, msg_id)
    elseif cmd == "PEER_SET" then
        return "PEER SET /locks/" .. string.format("%d", lock_id) .. " "
            .. fmt_u64(token) .. " " .. string.format("%d", holder) .. " " .. msg_id
    else
        error("unknown peer command: " .. tostring(cmd))
    end
end

return codec
