# Lunet

基于协程的高性能 LuaJIT 网络库，构建于 libuv 之上。

[English Documentation](README.md)

> 本项目基于 [夏磊 (Xia Lei)](https://github.com/xialeistudio) 的 [xialeistudio/lunet](https://github.com/xialeistudio/lunet)。详见他的精彩文章：[Lunet：高性能协程网络库的设计与实现](https://www.ddhigh.com/2025/07/12/lunet-high-performance-coroutine-network-library/)。

## 设计理念：无冗余，无臃肿

Lunet 采用**模块化设计**。只安装你需要的：

- **核心** (`lunet`)：TCP/UDP 套接字、文件系统、定时器、信号
- **数据库驱动** (独立包)：
  - `lunet-sqlite3` - SQLite3 驱动
  - `lunet-mysql` - MySQL/MariaDB 驱动
  - `lunet-postgres` - PostgreSQL 驱动

只安装一个数据库驱动，而不是全部。没有未使用的依赖。不需要为从未使用的库打安全补丁。

```bash
# 安装核心
luarocks install lunet

# 只安装你需要的数据库驱动
luarocks install lunet-sqlite3   # 或者
luarocks install lunet-mysql     # 或者
luarocks install lunet-postgres
```

### 为什么使用 lunet 数据库驱动？

你可能会想"我可以直接用 LuaJIT FFI 调用 sqlite3/libpq/libmysqlclient"——确实可以。但这些调用是**阻塞的**。它们会在等待数据库时冻结整个事件循环。

Lunet 数据库驱动是**协程安全的**：
- 查询在 libuv 线程池上运行 (`uv_work_t`)
- 连接使用互斥锁保护，支持安全的并发访问
- 协程在等待时让出执行权，其他协程继续运行

如果在 lunet 应用中使用原生 FFI 数据库绑定，你将失去所有异步优势。

## 构建

```bash
# 默认 SQLite 构建
make build

# 调试模式构建（启用追踪）
make build-debug
```

## RealWorld Conduit 示例

[RealWorld "Conduit"](https://github.com/gothinkster/realworld) API 实现位于 `app/` 目录。

```bash
# 1. 初始化 SQLite 数据库
sqlite3 conduit.db < app/schema_sqlite.sql

# 2. 启动服务器（端口 8080）
./build/lunet app/main.lua

# 3. 运行集成测试
./bin/test_api.sh
```

## 核心模块

所有网络操作必须在通过 `lunet.spawn` 创建的协程中调用。

### TCP / Unix 套接字 (`lunet.socket`)

```lua
local socket = require("lunet.socket")

-- 服务器
local listener = socket.listen("tcp", "127.0.0.1", 8080)
local client = socket.accept(listener)

-- 客户端
local conn = socket.connect("127.0.0.1", 8080)

-- I/O
local data = socket.read(conn)
socket.write(conn, "hello")
socket.close(conn)
```

### UDP (`lunet.udp`)

```lua
local udp = require("lunet.udp")

-- 绑定
local h = udp.bind("127.0.0.1", 20001)

-- I/O
udp.send(h, "127.0.0.1", 20002, "payload")
local data, host, port = udp.recv(h)

udp.close(h)
```

## 安全性：零开销追踪

使用 `make build-debug` 构建可启用协程引用追踪和栈完整性检查。运行时会在检测到泄漏或栈污染时触发断言并崩溃。

## 测试

```bash
make test    # 单元测试
make stress  # 带追踪的并发负载测试
```

## 许可证

MIT
