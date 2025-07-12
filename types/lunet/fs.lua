---@meta

---@class fs
local fs = {}

---Open a file
---@param path string The path to the file
---@param mode string The mode to open the file in ("r", "w", "a")
---@return integer|nil fd The file descriptor or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local fs = require('lunet.fs')
---local file, err = fs.open('test.txt', 'r')
---if err then
---    print('Error opening file: ' .. err)
---end
---print('File opened: ' .. file)
---```
function fs.open(path, mode) end

---Close a file
---@param fd integer The file descriptor to close
---@return string|nil error Error message if failed
---@usage
---```lua
---local fs = require('lunet.fs')
---local file, err = fs.open('test.txt', 'r')
---if err then
---    print('Error opening file: ' .. err)
---end
---fs.close(file)
---```
function fs.close(fd) end

---Get the size of a file
---@param path string The path to the file
---@return table|nil stat The stat of the file or nil on error
---@return string|nil error Error message if failed
function fs.stat(path) end

---Read from a file
---@param fd integer The file descriptor to read from
---@param size integer The number of bytes to read
---@return string|nil data The data read from the file or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local fs = require('lunet.fs')
---local file, err = fs.open('test.txt', 'r')
---if err then
---    print('Error opening file: ' .. err)
---end
---local data, err = fs.read(file, 1024)
---if err then
---    print('Error reading file: ' .. err)
---end
---print('Data read: ' .. data)
---```
function fs.read(fd, size) end

---Write to a file
---@param fd integer The file descriptor to write to
---@param data string The data to write to the file
---@return string|nil error Error message if failed
---@usage
---```lua
---local fs = require('lunet.fs')
---local file, err = fs.open('test.txt', 'w')
---if err then
---    print('Error opening file: ' .. err)
---end
---fs.write(file, 'Hello, world!')
---```
function fs.write(fd, data) end

---Scan a directory
---@param path string The path to the directory
---@return table|nil entries The entries in the directory or nil on error
---@return string|nil error Error message if failed
function fs.scandir(path) end

return fs
