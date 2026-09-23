---@meta

---@class websocket_listener
---@field _sock lightuserdata
---@field protocol string
---@field host string
---@field port integer

---@class websocket_conn
---@field id integer
---@field closed boolean

---@class websocket
local websocket = {}

websocket.TEXT = 1
websocket.BINARY = 2
websocket.CLOSE = 8
websocket.PING = 9
websocket.PONG = 10

---@param protocol string
---@param host string
---@param port integer
---@param opts? {registry?: boolean, max_header_bytes?: integer, max_message_size?: integer}
---@return websocket_listener|nil listener
---@return string|nil error
function websocket.listen(protocol, host, port, opts) end

---@param listener websocket_listener
---@param opts? {subprotocol?: string, max_header_bytes?: integer, max_message_size?: integer}
---@return websocket_conn|nil conn
---@return string|nil error
function websocket.accept(listener, opts) end

---@param client lightuserdata
---@param req? table
---@param opts? {listener?: websocket_listener, subprotocol?: string, max_header_bytes?: integer, max_message_size?: integer}
---@return websocket_conn|nil conn
---@return string|nil error
function websocket.upgrade(client, req, opts) end

---@param client lightuserdata
---@param max_header_bytes? integer
---@return table|nil req
---@return string|nil error
function websocket.read_http_request(client, max_header_bytes) end

---@param req table
---@return boolean
function websocket.is_upgrade_request(req) end

---@param conn websocket_conn
---@return string|nil data
---@return integer|nil opcode
---@return string|nil error
function websocket.recv(conn) end

---@param conn websocket_conn
---@param data string
---@param opcode? integer
---@return true|nil ok
---@return string|nil error
function websocket.send(conn, data, opcode) end

---@param conn websocket_conn
---@param data? string
---@return true|nil ok
---@return string|nil error
function websocket.ping(conn, data) end

---@param conn websocket_conn
---@param code? integer
---@param reason? string
---@return true|nil ok
---@return string|nil error
function websocket.close(conn, code, reason) end

---@param conn websocket_conn
---@return integer|nil id
function websocket.id(conn) end

---@param listener websocket_listener
---@return websocket_conn[] conns
function websocket.connections(listener) end

---@param listener websocket_listener
---@param data string
---@param opcode? integer
---@return integer sent_count
---@return string|nil first_error
function websocket.broadcast(listener, data, opcode) end

---@return nil
function websocket.enable_global_registry() end

---@class websocket_global_registry
---@field find_by_id fun(id: integer): websocket_conn|nil
---@field broadcast_all fun(data: string, opcode?: integer): integer, string|nil

---@type websocket_global_registry
websocket.global_registry = {}

return websocket