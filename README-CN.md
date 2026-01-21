# Lunet

基于协程的高性能 LuaJIT 网络库，构建于 libuv 之上。

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Language](https://img.shields.io/badge/Language-C%2BLuaJIT-green.svg)]()
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

[English Documentation](README.md)

## RealWorld Conduit API 示例

本仓库包含 RealWorld Conduit API（Medium.com 克隆）后端实现，示例文档见：

- [README_realworld-CN.md](README_realworld-CN.md)
- [README_realworld.md](README_realworld.md)

## 概述

Lunet 是一个基于协程的网络库，提供同步风格的 API，底层异步执行。它结合了 C、LuaJIT 和 libuv 的强大功能，在保持代码清晰可读的同时提供高性能的 I/O 操作。

### 核心特性

- **基于协程**：编写同步风格的代码，异步执行
- **高性能**：构建于 LuaJIT 和 libuv 之上，性能优异
- **功能全面**：包含文件系统、网络、数据库、信号和定时器操作
- **类型安全**：完整的类型定义，支持 IDE 智能提示
- **跨平台**：支持 Linux、macOS 和 Windows

## 架构

- **C 核心**：高性能的原生实现
- **LuaJIT**：快速的 Lua 执行环境，支持 FFI
- **libuv**：跨平台异步 I/O 库
- **协程**：使用 Lua 协程实现并发编程

## 模块

### 核心模块 (`lunet`)
- `spawn(func)`：创建并运行新协程
- `sleep(ms)`：挂起协程指定毫秒数

### 套接字模块 (`lunet.socket`)
- `listen(protocol, host, port)`：创建 TCP 服务器
- `accept(listener)`：接受传入连接
- `connect(host, port)`：连接到远程服务器
- `read(client)`：从套接字读取数据
- `write(client, data)`：向套接字写入数据
- `getpeername(client)`：获取对等地址
- `close(handle)`：关闭套接字
- `set_read_buffer_size(size)`：配置缓冲区大小

### 文件系统模块 (`lunet.fs`)
- `open(path, mode)`：打开文件
- `close(fd)`：关闭文件
- `read(fd, size)`：从文件读取
- `write(fd, data)`：写入文件
- `stat(path)`：获取文件统计信息
- `scandir(path)`：列出目录内容

### MySQL 模块 (`lunet.mysql`)
- `open(params)`：打开数据库连接
- `close(conn)`：关闭数据库连接
- `query(conn, query)`：执行 SELECT 查询
- `exec(conn, query)`：执行 INSERT/UPDATE/DELETE

### 信号模块 (`lunet.signal`)
- `wait(signal)`：等待系统信号

## 安装

### 前置条件

- CMake 3.10+
- LuaJIT 2.1+
- libuv 1.x
- MySQL 客户端库（MySQL 模块需要）

### 从源码构建

```bash
git clone https://github.com/xialeistudio/lunet.git
cd lunet
mkdir build && cd build
cmake ..
make
```

### 指定库路径构建

如果您的库安装在非标准位置，可以显式指定路径：

```bash
cmake .. \
  -DLUAJIT_INCLUDE_DIR=/path/to/luajit/include \
  -DLUAJIT_LIBRARY=/path/to/luajit/lib/libluajit-5.1.dylib \
  -DLIBUV_INCLUDE_DIR=/path/to/libuv/include \
  -DLIBUV_LIBRARY=/path/to/libuv/lib/libuv.dylib \
  -DMYSQL_INCLUDE_DIR=/path/to/mysql/include \
  -DMYSQL_LIBRARY=/path/to/mysql/lib/libmysqlclient.dylib
```

### macOS 使用 Homebrew

```bash
# 安装依赖
brew install luajit libuv mysql

# 自动检测构建
mkdir build && cd build
cmake ..
make

# 或者显式指定 Homebrew 路径
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
# 安装依赖
sudo apt update
sudo apt install build-essential cmake libluajit-5.1-dev libuv1-dev libmysqlclient-dev

# 构建
mkdir build && cd build
cmake ..
make
```

### CentOS/RHEL

```bash
# 安装依赖
sudo yum install gcc gcc-c++ cmake luajit-devel libuv-devel mysql-devel

# 构建
mkdir build && cd build
cmake ..
make
```

## 快速开始

### 简单的 HTTP 服务器

```lua
local lunet = require('lunet')
local socket = require('lunet.socket')

-- 创建服务器
local listener, err = socket.listen("tcp", "127.0.0.1", 8080)
if not listener then
    error("监听失败: " .. err)
end

print("服务器正在监听 http://127.0.0.1:8080")

-- 接受连接
lunet.spawn(function()
    while true do
        local client, err = socket.accept(listener)
        if client then
            -- 在新协程中处理客户端
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

### 文件操作

```lua
local lunet = require('lunet')
local fs = require('lunet.fs')

lunet.spawn(function()
    -- 写文件
    local file, err = fs.open('example.txt', 'w')
    if file then
        fs.write(file, 'Hello, Lunet!')
        fs.close(file)
    end
    
    -- 读文件
    local file, err = fs.open('example.txt', 'r')
    if file then
        local data, err = fs.read(file, 1024)
        if data then
            print('文件内容:', data)
        end
        fs.close(file)
    end
    
    -- 目录列表
    local entries, err = fs.scandir('.')
    if entries then
        for i, entry in ipairs(entries) do
            print('条目:', entry.name, entry.type)
        end
    end
end)
```

### 数据库操作

```lua
local lunet = require('lunet')
local mysql = require('lunet.mysql')

lunet.spawn(function()
    -- 连接数据库
    local conn, err = mysql.open({
        host = "localhost",
        port = 3306,
        user = "root",
        password = "password",
        database = "testdb"
    })
    
    if conn then
        -- 执行查询
        local result, err = mysql.query(conn, "SELECT * FROM users")
        if result then
            for i, row in ipairs(result) do
                print('用户:', row.name, row.email)
            end
        end
        
        -- 执行更新
        local result, err = mysql.exec(conn, "INSERT INTO users (name, email) VALUES ('John', 'john@example.com')")
        if result then
            print('影响行数:', result.affected_rows)
            print('最后插入 ID:', result.last_insert_id)
        end
        
        mysql.close(conn)
    end
end)
```

## 使用方法

使用 lunet 运行您的 Lua 脚本：

```bash
./lunet script.lua
```

## 类型定义

Lunet 包含完整的类型定义以支持 IDE 智能提示。类型文件位于 `types/` 目录：

- `types/lunet.lua` - 核心模块类型
- `types/lunet/socket.lua` - 套接字模块类型  
- `types/lunet/fs.lua` - 文件系统模块类型
- `types/lunet/mysql.lua` - MySQL 模块类型
- `types/lunet/signal.lua` - 信号模块类型

## 性能

Lunet 专为高性能而设计：

- **零拷贝**：最少的内存分配和拷贝
- **协程**：高效的协作式多任务
- **libuv**：经过实战考验的异步 I/O
- **LuaJIT**：即时编译实现快速执行

## 贡献

欢迎贡献！请随时提交问题和拉取请求。

### 开发

1. Fork 仓库
2. 创建功能分支
3. 进行更改
4. 添加测试（如适用）
5. 提交拉取请求

## 许可证

本项目采用 MIT 许可证 - 详情请参阅 [LICENSE](LICENSE) 文件。

## 致谢

- [LuaJIT](https://luajit.org/) - 快速的 Lua 实现
- [libuv](https://libuv.org/) - 跨平台异步 I/O
- [MySQL](https://www.mysql.com/) - 数据库连接
