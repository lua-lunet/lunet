# Lunet

A high-performance coroutine-based networking library for LuaJIT, built on top of libuv.

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Language](https://img.shields.io/badge/Language-C%2BLuaJIT-green.svg)]()
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

[中文文档](README-CN.md)

## Overview

Lunet is a coroutine-based networking library that provides synchronous APIs with asynchronous execution. It combines the power of C, LuaJIT, and libuv to deliver high-performance I/O operations while maintaining clean, readable code.

### Key Features

- **Coroutine-based**: Write synchronous-style code that runs asynchronously
- **High Performance**: Built on LuaJIT and libuv for optimal performance
- **Comprehensive**: Includes filesystem, networking, database, signal, and timer operations
- **Type Safety**: Complete type definitions for IDE support
- **Cross-platform**: Works on Linux, macOS, and Windows

## Architecture

- **C Core**: High-performance native implementation
- **LuaJIT**: Fast Lua execution with FFI support
- **libuv**: Cross-platform asynchronous I/O
- **Coroutines**: Lua coroutines for concurrent programming

## Modules

### Core Module (`lunet`)
- `spawn(func)`: Create and run a new coroutine
- `sleep(ms)`: Suspend coroutine for specified milliseconds

### Socket Module (`lunet.socket`)
- `listen(protocol, host, port)`: Create TCP server
- `accept(listener)`: Accept incoming connections
- `connect(host, port)`: Connect to remote server
- `read(client)`: Read data from socket
- `write(client, data)`: Write data to socket
- `getpeername(client)`: Get peer address
- `close(handle)`: Close socket
- `set_read_buffer_size(size)`: Configure buffer size

### Filesystem Module (`lunet.fs`)
- `open(path, mode)`: Open file
- `close(fd)`: Close file
- `read(fd, size)`: Read from file
- `write(fd, data)`: Write to file
- `stat(path)`: Get file statistics
- `scandir(path)`: List directory contents

### MySQL Module (`lunet.mysql`)
- `open(params)`: Open database connection
- `close(conn)`: Close database connection
- `query(conn, query)`: Execute SELECT query
- `exec(conn, query)`: Execute INSERT/UPDATE/DELETE

### Signal Module (`lunet.signal`)
- `wait(signal)`: Wait for system signal

## Installation

### Prerequisites

- CMake 3.10+
- LuaJIT 2.1+
- libuv 1.x
- MySQL client library (for MySQL module)

### Build from Source

```bash
git clone https://github.com/xialeistudio/lunet.git
cd lunet
mkdir build && cd build
cmake ..
make
```

### Build with Custom Library Paths

If you have libraries installed in non-standard locations, you can specify the paths explicitly:

```bash
cmake .. \
  -DLUAJIT_INCLUDE_DIR=/path/to/luajit/include \
  -DLUAJIT_LIBRARY=/path/to/luajit/lib/libluajit-5.1.dylib \
  -DLIBUV_INCLUDE_DIR=/path/to/libuv/include \
  -DLIBUV_LIBRARY=/path/to/libuv/lib/libuv.dylib \
  -DMYSQL_INCLUDE_DIR=/path/to/mysql/include \
  -DMYSQL_LIBRARY=/path/to/mysql/lib/libmysqlclient.dylib
```

### macOS with Homebrew

```bash
# Install dependencies
brew install luajit libuv mysql

# Build with automatic detection
mkdir build && cd build
cmake ..
make

# Or specify Homebrew paths explicitly
cmake .. \
  -DLUAJIT_INCLUDE_DIR=/opt/homebrew/include/luajit-2.1 \
  -DLUAJIT_LIBRARY=/opt/homebrew/lib/libluajit-5.1.dylib \
  -DLIBUV_INCLUDE_DIR=/opt/homebrew/include \
  -DLIBUV_LIBRARY=/opt/homebrew/lib/libuv.dylib \
  -DMYSQL_INCLUDE_DIR=/opt/homebrew/Cellar/mysql@8.4/8.4.4/include \
  -DMYSQL_LIBRARY=/opt/homebrew/Cellar/mysql@8.4/8.4.4/lib/libmysqlclient.dylib
```

### Ubuntu/Debian

```bash
# Install dependencies
sudo apt update
sudo apt install build-essential cmake libluajit-5.1-dev libuv1-dev libmysqlclient-dev

# Build
mkdir build && cd build
cmake ..
make
```

### CentOS/RHEL

```bash
# Install dependencies
sudo yum install gcc gcc-c++ cmake luajit-devel libuv-devel mysql-devel

# Build
mkdir build && cd build
cmake ..
make
```

## Quick Start

### Simple HTTP Server

```lua
local lunet = require('lunet')
local socket = require('lunet.socket')

-- Create server
local listener, err = socket.listen("tcp", "127.0.0.1", 8080)
if not listener then
    error("Failed to listen: " .. err)
end

print("Server listening on http://127.0.0.1:8080")

-- Accept connections
lunet.spawn(function()
    while true do
        local client, err = socket.accept(listener)
        if client then
            -- Handle client in new coroutine
            lunet.spawn(function()
                local data, err = socket.read(client)
                if data then
                    local response = "HTTP/1.1 200 OK\r\n" ..
                                   "Content-Type: text/plain\r\n" ..
                                   "Content-Length: 13\r\n\r\n" ..
                                   "Hello, World!"
                    socket.write(client, response)
                end
                socket.close(client)
            end)
        end
    end
end)
```

### File Operations

```lua
local lunet = require('lunet')
local fs = require('lunet.fs')

lunet.spawn(function()
    -- Write file
    local file, err = fs.open('example.txt', 'w')
    if file then
        fs.write(file, 'Hello, Lunet!')
        fs.close(file)
    end
    
    -- Read file
    local file, err = fs.open('example.txt', 'r')
    if file then
        local data, err = fs.read(file, 1024)
        if data then
            print('File content:', data)
        end
        fs.close(file)
    end
    
    -- Directory listing
    local entries, err = fs.scandir('.')
    if entries then
        for i, entry in ipairs(entries) do
            print('Entry:', entry.name, entry.type)
        end
    end
end)
```

### Database Operations

```lua
local lunet = require('lunet')
local mysql = require('lunet.mysql')

lunet.spawn(function()
    -- Connect to database
    local conn, err = mysql.open({
        host = "localhost",
        port = 3306,
        user = "root",
        password = "password",
        database = "testdb"
    })
    
    if conn then
        -- Execute query
        local result, err = mysql.query(conn, "SELECT * FROM users")
        if result then
            for i, row in ipairs(result) do
                print('User:', row.name, row.email)
            end
        end
        
        -- Execute update
        local result, err = mysql.exec(conn, "INSERT INTO users (name, email) VALUES ('John', 'john@example.com')")
        if result then
            print('Affected rows:', result.affected_rows)
            print('Last insert ID:', result.last_insert_id)
        end
        
        mysql.close(conn)
    end
end)
```

## Usage

Run your Lua script with lunet:

```bash
./lunet script.lua
```

## Type Definitions

Lunet includes comprehensive type definitions for IDE support. The type files are located in the `types/` directory:

- `types/lunet.lua` - Core module types
- `types/lunet/socket.lua` - Socket module types  
- `types/lunet/fs.lua` - Filesystem module types
- `types/lunet/mysql.lua` - MySQL module types
- `types/lunet/signal.lua` - Signal module types

## Performance

Lunet is designed for high performance:

- **Zero-copy**: Minimal memory allocation and copying
- **Coroutines**: Efficient cooperative multitasking
- **libuv**: Battle-tested asynchronous I/O
- **LuaJIT**: Just-in-time compilation for fast execution

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

### Development

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## Examples

| Example | Description |
|---------|-------------|
| [01_json.lua](examples/01_json.lua) | Pure Lua JSON encoding with MySQL integration |
| [02_routing.lua](examples/02_routing.lua) | HTTP routing with URL parameter extraction (`:id`) |
| [03_mcp_sse.lua](examples/03_mcp_sse.lua) | MCP SSE server with Tavily search (18x smaller than Node.js) |
| [mcp_stdio_pure.lua](examples/mcp_stdio_pure.lua) | Pure Lua stdio MCP for ablation testing |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [LuaJIT](https://luajit.org/) - Fast Lua implementation
- [libuv](https://libuv.org/) - Cross-platform asynchronous I/O
- [MySQL](https://www.mysql.com/) - Database connectivity
