local M = {}

function M.new()
    return {}
end

function M.pack_token(lock_id, holder)
    return lock_id * 0x100000000ULL + holder
end

function M.unpack_token(token)
    local lock_id = tonumber(token / 0x100000000ULL)
    local holder = tonumber(token % 0x100000000ULL)
    return lock_id, holder
end

function M.get(tbl, lock_id)
    local entry = tbl[lock_id]
    if entry then
        return entry.holder, entry.token
    end
    return 0, M.pack_token(lock_id, 0)
end

function M.cas(tbl, lock_id, expected_token, new_holder)
    local entry = tbl[lock_id]
    if not entry then
        local new_token = M.pack_token(lock_id, new_holder)
        tbl[lock_id] = { holder = new_holder, token = new_token }
        return true, new_token
    end
    if entry.token == expected_token then
        local new_token = M.pack_token(lock_id, new_holder)
        tbl[lock_id] = { holder = new_holder, token = new_token }
        return true, new_token
    end
    return false, entry.token
end

return M
