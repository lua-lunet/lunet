---@meta

---@class socket
local socket = {}

---Listen for incoming connections
---@param protocol string Protocol type, only "tcp" is supported
---@param host string Host address to bind to (e.g., "127.0.0.1", "0.0.0.0")
---@param port integer Port number to listen on (1-65535)
---@return lightuserdata|nil listener The listener handle or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local socket = require('lunet.socket')
---local listener, err = socket.listen("tcp", "127.0.0.1", 8080)
---if not listener then
---    error("Failed to listen: " .. err)
---end
---```
function socket.listen(protocol, host, port) end

---Accept an incoming connection (must be called from coroutine)
---@param listener lightuserdata The listener handle from socket.listen()
---@return lightuserdata|nil client The client handle or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local socket = require('lunet.socket')
---lunet.spawn(function()
---    local client, err = socket.accept(listener)
---    if not client then
---        error("Accept failed: " .. err)
---    end
---    -- Handle client connection
---end)
---```
function socket.accept(listener) end

---Get the peer address of a connected socket
---@param client lightuserdata The client handle from socket.accept()
---@return string|nil address The peer address string "ip:port" or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local socket = require('lunet.socket')
---local addr, err = socket.getpeername(client)
---if addr then
---    print("Client from: " .. addr)
---end
---```
function socket.getpeername(client) end

---Read data from a socket (must be called from coroutine)
---@param client lightuserdata The client handle
---@return string|nil data The received data or nil on error/EOF
---@return string|nil error Error message if failed
---@usage
---```lua
---local socket = require('lunet.socket')
---lunet.spawn(function()
---    local data, err = socket.read(client)
---    if data then
---        print("Received: " .. data)
---    elseif err then
---        print("Read error: " .. err)
---    else
---        print("Connection closed")
---    end
---end)
---```
function socket.read(client) end

---Write data to a socket (must be called from coroutine)
---@param client lightuserdata The client handle
---@param data string The data to send
---@return string|nil error Error message if failed
---@usage
---```lua
---local socket = require('lunet.socket')
---lunet.spawn(function()
---    local ok, err = socket.write(client, "Hello, client!")
---    if not ok then
---        print("Write error: " .. err)
---    end
---end)
---```
function socket.write(client, data) end

---Close a socket or listener
---@param handle lightuserdata The socket handle to close
---@usage
---```lua
---local socket = require('lunet.socket')
---socket.close(client)
---socket.close(listener)
---```
function socket.close(handle) end

---Set the read buffer size for a socket
---@param size integer The new read buffer size
---@return nil
---@usage
---```lua
---local socket = require('lunet.socket')
---socket.set_read_buffer_size(1024)
---```
function socket.set_read_buffer_size(size) end

---Connect to a server
---@param host string The server host
---@param port integer The server port
---@return lightuserdata|nil conn The connection handle or nil on error
---@return string|nil error Error message if failed
function socket.connect(host, port) end

return socket
