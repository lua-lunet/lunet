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
xmake build-release

# 调试模式构建（启用追踪）
xmake build-debug
```

## 示例应用

完整的 RealWorld "Conduit" API 实现请参见 [lunet-realworld-example-app](https://github.com/lua-lunet/lunet-realworld-example-app)。

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

## 数据库驱动

数据库驱动是**独立的包**。只安装你需要的：

```bash
luarocks install lunet-sqlite3   # SQLite3
luarocks install lunet-mysql     # MySQL/MariaDB
luarocks install lunet-postgres  # PostgreSQL
```

### SQLite3 (`lunet.sqlite3`)

```lua
local db = require("lunet.sqlite3")

-- 打开数据库（文件路径或 ":memory:"）
local conn = db.open("myapp.db")

-- 执行语句（INSERT/UPDATE/DELETE）- 返回影响的行数
local rows = db.exec(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

-- 查询（SELECT）- 返回行表数组
local users = db.query(conn, "SELECT * FROM users WHERE active = 1")
for _, user in ipairs(users) do
    print(user.id, user.name)
end

-- 参数化查询（防止 SQL 注入）
local results = db.query_params(conn, "SELECT * FROM users WHERE name = ?", "alice")
db.exec_params(conn, "INSERT INTO users (name) VALUES (?)", "bob")

-- 转义字符串（用于动态 SQL - 尽量使用参数化查询）
local safe = db.escape(conn, "O'Brien")

-- 关闭连接
db.close(conn)
```

### MySQL/MariaDB (`lunet.mysql`)

```lua
local db = require("lunet.mysql")

-- 打开连接
local conn = db.open({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "secret",
    database = "myapp"
})

-- 与 SQLite3 相同的 API
local users = db.query(conn, "SELECT * FROM users")
db.exec_params(conn, "INSERT INTO users (name) VALUES (?)", "alice")

db.close(conn)
```

### PostgreSQL (`lunet.postgres`)

```lua
local db = require("lunet.postgres")

-- 打开连接
local conn = db.open({
    host = "127.0.0.1",
    port = 5432,
    user = "postgres",
    password = "secret",
    database = "myapp"
})

-- 与 SQLite3 相同的 API
local users = db.query(conn, "SELECT * FROM users")
db.exec_params(conn, "INSERT INTO users (name) VALUES ($1)", "alice")  -- PostgreSQL 使用 $1, $2 等

db.close(conn)
```

### 数据库 API 概览

| 函数 | 描述 | 返回值 |
|------|------|--------|
| `db.open(path_or_config)` | 打开连接 | 连接句柄 |
| `db.close(conn)` | 关闭连接 | - |
| `db.query(conn, sql)` | 执行 SELECT | 行表数组 |
| `db.exec(conn, sql)` | 执行 INSERT/UPDATE/DELETE | 影响行数 |
| `db.query_params(conn, sql, ...)` | 参数化 SELECT | 行表数组 |
| `db.exec_params(conn, sql, ...)` | 参数化 INSERT/UPDATE/DELETE | 影响行数 |
| `db.escape(conn, str)` | 转义 SQL 字符串 | 转义后的字符串 |

## 安全性：零开销追踪

使用 `xmake build-debug` 构建可启用协程引用追踪和栈完整性检查。运行时会在检测到泄漏或栈污染时触发断言并崩溃。

## 测试

```bash
xmake test    # 单元测试
xmake stress  # 带追踪的并发负载测试
```

## 许可证

MIT
