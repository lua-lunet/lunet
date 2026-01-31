---@meta

---@class unix
---Unix domain socket module for local inter-process communication.
---Provides non-blocking Unix socket operations for coroutine-based async I/O.
local unix = {}

---Listen on a Unix domain socket
---@param path string The socket file path (e.g., "/tmp/my.sock")
---@return lightuserdata|nil listener The listener handle or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local unix = require('lunet.unix')
---local lunet = require('lunet')
---lunet.spawn(function()
---    local listener, err = unix.listen("/tmp/my.sock")
---    if not listener then
---        error("Failed to listen: " .. err)
---    end
---    -- Accept connections...
---end)
---```
function unix.listen(path) end

---Accept an incoming connection on a Unix socket listener
---@param listener lightuserdata The listener handle from unix.listen()
---@return lightuserdata|nil client The client handle or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local unix = require('lunet.unix')
---lunet.spawn(function()
---    local client, err = unix.accept(listener)
---    if not client then
---        error("Accept failed: " .. err)
---    end
---    -- Handle client connection
---end)
---```
function unix.accept(listener) end

---Connect to a Unix domain socket
---@param path string The socket file path to connect to
---@return lightuserdata|nil client The client handle or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local unix = require('lunet.unix')
---lunet.spawn(function()
---    local client, err = unix.connect("/tmp/my.sock")
---    if not client then
---        error("Connect failed: " .. err)
---    end
---    -- Use client...
---end)
---```
function unix.connect(path) end

---Read data from a Unix socket client (must be called from coroutine)
---@param client lightuserdata The client handle
---@return string|nil data The received data or nil on error/EOF
---@return string|nil error Error message if failed
---@usage
---```lua
---local unix = require('lunet.unix')
---lunet.spawn(function()
---    local data, err = unix.read(client)
---    if data then
---        print("Received: " .. data)
---    elseif err then
---        print("Read error: " .. err)
---    else
---        print("Connection closed")
---    end
---end)
---```
function unix.read(client) end

---Write data to a Unix socket client (must be called from coroutine)
---@param client lightuserdata The client handle
---@param data string The data to send
---@return string|nil error nil on success, error message if failed
---@usage
---```lua
---local unix = require('lunet.unix')
---lunet.spawn(function()
---    local err = unix.write(client, "Hello!")
---    if err then
---        print("Write error: " .. err)
---    end
---end)
---```
function unix.write(client, data) end

---Close a Unix socket (listener or client)
---@param handle lightuserdata The socket handle to close
---@return string|nil error nil on success, error message if failed
---@usage
---```lua
---local unix = require('lunet.unix')
---unix.close(client)
---unix.close(listener)
---```
function unix.close(handle) end

---Get the peer name for a Unix socket client
---@param client lightuserdata The client handle
---@return string|nil name The peer name or "unix" if not available
---@return string|nil error Error message if failed
---@usage
---```lua
---local unix = require('lunet.unix')
---local name, err = unix.getpeername(client)
---print("Peer: " .. (name or "unknown"))
---```
function unix.getpeername(client) end

---Remove a Unix socket file (convenience cleanup function)
---@param path string The socket file path to remove
---@return string|nil error nil on success, error message if failed
---@usage
---```lua
---local unix = require('lunet.unix')
---unix.unlink("/tmp/my.sock")  -- Clean up before listen
---```
function unix.unlink(path) end

---Set the read buffer size for Unix socket operations
---@param size integer The new read buffer size in bytes
---@return nil
---@usage
---```lua
---local unix = require('lunet.unix')
---unix.set_read_buffer_size(8192)
---```
function unix.set_read_buffer_size(size) end

return unix
