# Lunet

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Language](https://img.shields.io/badge/Language-C%2BLuaJIT-green.svg)]()
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

[中文文档](README-CN.md)

A high-performance coroutine-based networking library for LuaJIT, built on top of libuv:

> Lunet is a high-performance runtime written in C that integrates LuaJIT and libuv, focusing on coroutine-driven asynchronous programming.  
> 
> Lunet’s architectural design fully embodies the philosophy of “standing on the shoulders of giants” 
> 
> It simplifies the handling of asynchronous I/O and blocking tasks, enabling developers to easily write high-concurrency network applications using Lua scripts.
> 
> [Lunet: Design and Implementation of a High-Performance Coroutine Network Library](https://www.ddhigh.com/en/2025/07/12/lunet-high-performance-coroutine-network-library/)

## RealWorld Conduit API Demo

This fork includes an implementation of the [RealWorld "Conduit"](https://github.com/gothinkster/realworld) API spec - a Medium.com clone demonstrating Lunet's capabilities as a web backend framework. The implementation covers users, profiles, articles, comments, tags, favorites, and follows endpoints. The app is located in the `app/` directory.

Docs: [README_realworld.md](README_realworld.md) | [README_realworld-CN.md](README_realworld-CN.md)

### Demo Prerequisites

- CMake 3.12+, LuaJIT 2.1+, libuv 1.x, libsodium
- **Database Backend**: Selected at compile time via `LUNET_DB` CMake variable
  - **sqlite3** (default): No external service required
  - **postgres**: Requires PostgreSQL server and `libpq` library
  - **mysql**: Requires MySQL/MariaDB server and `libmysqlclient` library

### Build Configuration

**Using Make (recommended):**
```bash
# Default SQLite build
make build

# Or specify database backend
make build-sqlite   # SQLite3
make build-postgres # PostgreSQL  
make build-mysql    # MySQL/MariaDB
```

**Using CMake directly:**
```bash
# SQLite (default)
cmake -B build -DLUNET_DB=sqlite3
cmake --build build

# PostgreSQL
cmake -B build -DLUNET_DB=postgres
cmake --build build

# MySQL
cmake -B build -DLUNET_DB=mysql
cmake --build build
```

### Demo API Quick Start

```bash
# Build lunet (compiles C core with CMake)
cmake -B build
cmake --build build

# Initialize database (SQLite)
# The app will automatically initialize the SQLite database at .tmp/conduit.sqlite3 on first run.

# Start the API backend (listens on port 8080)
# Linux/macOS:
./build/lunet app/main.lua
# Windows:
.\build\Release\lunet.exe app\main.lua

# Verify API is running
bin/test_curl.sh http://127.0.0.1:8080/api/tags
```
# (Optional) Start a React/Vite frontend - clones to .tmp/conduit-vite
make wui

# Stop all services
make stop
```

### Demo Make Targets

| Target | Description |
|--------|-------------|
| `make build` | Compile lunet C core using CMake |
| `make run` | Start the API backend on port 8080 |
| `make wui` | Clone and start React/Vite frontend (requires bun or npm) |
| `make stop` | Stop API backend and frontend |
| `make test` | Run unit tests with busted |
| `make check` | Run static analysis with luacheck |
| `make help` | Show all available targets |

This contribution builds upon the upstream [xialeistudio/lunet](https://github.com/xialeistudio/lunet) project.

---

## Lunet Overview

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

### Database Module (`lunet.db`)

The database module provides a unified API across SQLite, PostgreSQL, and MySQL backends:

- `open(params)`: Open database connection
- `close(conn)`: Close database connection
- `query(conn, sql)`: Execute SELECT query, returns rows
- `exec(conn, sql)`: Execute INSERT/UPDATE/DELETE
- `escape(str)`: Escape string for safe SQL interpolation (uses backend-specific escaping syntax)

The backend is selected at compile time. Each backend uses its appropriate escaping syntax:
- **SQLite/PostgreSQL**: Quote doubling (`'` → `''`)
- **MySQL**: Backslash escaping (`'` → `\'`, `\` → `\\`)

### Signal Module (`lunet.signal`)
- `wait(signal)`: Wait for system signal

## Installation

### Prerequisites

- CMake 3.10+
- LuaJIT 2.1+
- libuv 1.x
- libsodium
- **Database Library** (one of the following, matching your build choice):
  - SQLite3
  - PostgreSQL (`libpq`)
  - MySQL client library (`libmysqlclient`)

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

> **Note**: For macOS users with Homebrew, see the [macOS with Homebrew](#macos-with-homebrew) section below for automatic path detection.

### macOS with Homebrew

```bash
# Install dependencies
brew install luajit libuv libsodium sqlite postgresql mysql

# Build with automatic detection (recommended)
# CMake will automatically find Homebrew libraries in /opt/homebrew
make build           # SQLite (default)
make build-postgres  # PostgreSQL
make build-mysql     # MySQL

# Finding library paths (for manual cmake invocation)
# Use `brew --prefix <package>` to find installation paths:
brew --prefix luajit     # /opt/homebrew/opt/luajit
brew --prefix libuv      # /opt/homebrew/opt/libuv
brew --prefix libsodium  # /opt/homebrew/opt/libsodium
brew --prefix sqlite     # /opt/homebrew/opt/sqlite
brew --prefix libpq      # /opt/homebrew/opt/libpq
brew --prefix mysql      # /opt/homebrew/opt/mysql

# Manual CMake with explicit paths (if auto-detection fails):
cmake -B build -DLUNET_DB=sqlite3 \
  -DLUAJIT_INCLUDE_DIR=$(brew --prefix luajit)/include/luajit-2.1 \
  -DLUAJIT_LIBRARY=$(brew --prefix luajit)/lib/libluajit-5.1.dylib \
  -DSODIUM_INCLUDE_DIR=$(brew --prefix libsodium)/include \
  -DSODIUM_LIBRARY=$(brew --prefix libsodium)/lib/libsodium.dylib \
  -DSQLITE3_INCLUDE_DIR=$(brew --prefix sqlite)/include \
  -DSQLITE3_LIBRARY=$(brew --prefix sqlite)/lib/libsqlite3.dylib
cmake --build build
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
local db = require('lunet.db')

lunet.spawn(function()
    -- Connect to database (params depend on backend)
    -- SQLite: { path = "database.sqlite3" }
    -- PostgreSQL: { host, port, user, password, database }
    -- MySQL: { host, port, user, password, database }
    local conn, err = db.open({
        host = "localhost",
        port = 5432,
        user = "postgres",
        password = "password",
        database = "testdb"
    })
    
    if conn then
        -- Safe string escaping (uses native backend escaping)
        local safe_name = db.escape("O'Reilly")
        
        -- Execute query
        local result, err = db.query(conn, "SELECT * FROM users")
        if result then
            for i, row in ipairs(result) do
                print('User:', row.name, row.email)
            end
        end
        
        -- Execute insert with escaped values
        local sql = string.format(
            "INSERT INTO users (name, email) VALUES (%s, %s)",
            db.escape("John"),
            db.escape("john@example.com")
        )
        local result, err = db.exec(conn, sql)
        if result then
            print('Insert successful')
        end
        
        db.close(conn)
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
- `types/lunet/db.lua` - Unified database module types
- `types/lunet/signal.lua` - Signal module types

## Performance

Lunet is designed for high performance:

- **Zero-copy**: Minimal memory allocation and copying
- **Coroutines**: Efficient cooperative multitasking
- **libuv**: Battle-tested asynchronous I/O
- **LuaJIT**: Just-in-time compilation for fast execution

## Safety: Zero-Cost Tracing

Lunet includes a compile-time optional tracing system for detecting concurrency bugs:

- **Stack pollution detection**: Catches Lua-C stack corruption bugs
- **Coroutine reference tracking**: Detects leaks and double-releases
- **Zero overhead in release**: All tracing code is eliminated by the compiler

### Debug Build (with tracing)

```bash
# Build with tracing enabled - assertions crash on bugs
make build-debug

# Or via CMake directly
cmake -B build -DLUNET_TRACE=ON -DLUNET_DB=sqlite3
cmake --build build
```

When `LUNET_TRACE=ON`, the runtime will:
- Track all coroutine reference create/release operations
- Verify stack integrity after every `lunet_ensure_coroutine()` call
- Print statistics at shutdown
- Assert and crash if references are unbalanced

### Stress Testing

Run concurrent stress tests to expose race conditions:

```bash
make stress   # Debug build + concurrent load test
```

### Release Build

```bash
make release  # Runs tests, stress test, then builds optimized release
```

The release build has **zero tracing overhead** - all macros compile to no-ops.

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
| [01_json.lua](examples/01_json.lua) | Pure Lua JSON encoding with database integration |
| [02_routing.lua](examples/02_routing.lua) | HTTP routing with URL parameter extraction (`:id`) |
| [03_mcp_sse.lua](examples/03_mcp_sse.lua) | MCP SSE server with Tavily search (18x smaller than Node.js) |
| [mcp_stdio_pure.lua](examples/mcp_stdio_pure.lua) | Pure Lua stdio MCP for ablation testing |

## Modular LuaRocks Packages

Lunet is distributed as modular LuaRocks packages, enabling minimal installations for lightweight use cases.

### Package Structure

| Package | Purpose | Dependencies |
|---------|---------|--------------|
| **lunet-core** | Event loop, coroutines, sockets, JSON | libuv, luajit, libsodium |
| **lunet-sqlite3** | SQLite3 driver | lunet-core, sqlite3 |
| **lunet-mysql** | MySQL driver | lunet-core, libmysqlclient |
| **lunet-postgres** | PostgreSQL driver | lunet-core, libpq |

### Installing from GitHub

Rockspecs are available in the `rocks/` directory and can be installed directly:

```bash
# Install from GitHub (using rockspec URL)
luarocks install https://raw.githubusercontent.com/lua-lunet/lunet/main/rocks/lunet-core-scm-0.rockspec

# Or clone and install locally
git clone https://github.com/lua-lunet/lunet.git
cd lunet
luarocks make rocks/lunet-core-scm-0.rockspec
```

### Validating Rockspecs

```bash
# Validate all rockspecs
make rocks
```

The `rocks/` directory contains rockspecs following LuaRocks conventions. Distribution is via GitHub (Releases, Pages, or direct URLs).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [LuaJIT](https://luajit.org/) - Fast Lua implementation
- [libuv](https://libuv.org/) - Cross-platform asynchronous I/O
- [MySQL](https://www.mysql.com/) - Database connectivity
- [Xia Lei](https://github.com/xialeistudio) - Project originator / Original author


