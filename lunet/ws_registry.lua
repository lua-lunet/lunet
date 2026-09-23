local M = {}

local next_conn_id = 0
local global_enabled = false
local global_by_id = setmetatable({}, { __mode = "v" })

local function new_weak_values()
  return setmetatable({}, { __mode = "v" })
end

function M.next_id()
  next_conn_id = next_conn_id + 1
  return next_conn_id
end

function M.new_listener_registry()
  return {
    by_id = new_weak_values(),
  }
end

function M.enable_global_registry()
  global_enabled = true
end

function M.register(listener, conn)
  if listener and listener._registry then
    listener._registry.by_id[conn.id] = conn
  end
  if global_enabled then
    global_by_id[conn.id] = conn
  end
end

function M.unregister(listener, conn)
  if listener and listener._registry then
    listener._registry.by_id[conn.id] = nil
  end
  if global_enabled then
    global_by_id[conn.id] = nil
  end
end

function M.listener_connections(listener)
  local out = {}
  if not listener or not listener._registry then
    return out
  end
  for _, conn in pairs(listener._registry.by_id) do
    if conn and not conn.closed then
      out[#out + 1] = conn
    end
  end
  return out
end

function M.global_connections()
  local out = {}
  if not global_enabled then
    return out
  end
  for _, conn in pairs(global_by_id) do
    if conn and not conn.closed then
      out[#out + 1] = conn
    end
  end
  return out
end

function M.global_find(id)
  if not global_enabled then
    return nil
  end
  return global_by_id[id]
end

return M