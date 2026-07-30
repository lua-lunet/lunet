---@meta

---@class udp
local udp = {}

---Bind a UDP socket to host:port and start receiving datagrams.
---@param host string
---@param port integer
---@return lightuserdata|nil handle
---@return string|nil error
function udp.bind(host, port) end

---Send a datagram.
---@param handle lightuserdata
---@param host string
---@param port integer
---@param data string
---@return boolean|nil ok
---@return string|nil error
function udp.send(handle, host, port, data) end

---Receive a datagram if one is available.
---Returns nils if none are queued (caller can yield/sleep).
---@param handle lightuserdata
---@return string|nil data
---@return string|nil peer_host
---@return integer|nil peer_port
function udp.recv(handle) end

---Close the UDP socket.
---@param handle lightuserdata
---@return boolean|nil ok
---@return string|nil error
function udp.close(handle) end

---Get the local address and port of a bound UDP socket.
---@param handle lightuserdata
---@return string|nil host The local host address
---@return integer|nil port The local port number
---@return string|nil error Error message if failed
function udp.getsockname(handle) end

return udp
