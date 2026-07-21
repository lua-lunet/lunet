# Lunet

基于协程的高性能 LuaJIT 网络库，构建于 libuv 之上。

[English Documentation](README.md)

[![EasyMem](https://img.shields.io/badge/EasyMem-easy__memory-27272d?style=flat&logo=github&logoColor=white)](https://github.com/EasyMem/easy_memory)

> 本项目基于 [夏磊 (Xia Lei)](https://github.com/xialeistudio) 的 [xialeistudio/lunet](https://github.com/xialeistudio/lunet)。详见他的精彩文章：[Lunet：高性能协程网络库的设计与实现](https://www.ddhigh.com/2025/07/12/lunet-high-performance-coroutine-network-library/)。

## 设计理念：无冗余，无臃肿

Lunet 采用**模块化设计**。只构建你需要的：

- **核心** (`lunet`)：TCP/UDP 套接字、文件系统、定时器、信号
- **数据库驱动**（可选 xmake 目标）：
  - `lunet-sqlite3` - SQLite3 驱动
  - `lunet-mysql` - MySQL/MariaDB 驱动
  - `lunet-postgres` - PostgreSQL 驱动
- **出站 HTTPS 客户端**（可选 xmake 目标）：
  - `lunet-httpc` - 基于 libcurl 的 HTTPS 客户端（`require("lunet.httpc")`）
- **共享字典**（可选 Rust 扩展，Linux/macOS）：
  - `lunet.ngx_shared` - 受 nginx 启发的共享字典，通过 Rust FFI 实现（`xmake build-ngx-shared`）
- **JSON**（可选 Rust 扩展，Linux/macOS）：
  - `lunet.jsonic` - dkjson 风格的编解码；解码通过 Rust FFI 封装 [jsonic](https://github.com/g1mv/jsonic)（`xmake build-jsonic`）
- **图数据库**（可选 Rust 扩展，从源码构建，Linux/macOS）：
  - `lunet.graphlite` - 基于 [GraphLite](https://github.com/GraphLite-AI/GraphLite) Rust FFI 的 ISO GQL 图数据库（`xmake build-graphlite`）

只构建一个数据库驱动，而不是全部。没有未使用的依赖。不需要为从未使用的库打安全补丁。

入门（完整构建流程、配置档位、集成方式）：
- **[docs/XMAKE_INTEGRATION.md](docs/XMAKE_INTEGRATION.md)**
- **[docs/HTTPC-CN.md](docs/HTTPC-CN.md)**（可选出站 HTTPS 客户端）

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

发布档位默认会剥离 EasyMem。若需 EasyMem 诊断，请使用 debug/ASan 档位。

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

数据库驱动是**可选构建目标**。只构建你需要的：

```bash
xmake build lunet-sqlite3   # SQLite3
xmake build lunet-mysql     # MySQL/MariaDB
xmake build lunet-postgres  # PostgreSQL
```

### SQLite3 (`lunet.sqlite3`)

```lua
local db = require("lunet.sqlite3")

-- 打开数据库（文件路径或 ":memory:"）
local conn = db.open("myapp.db")

-- 执行语句（INSERT/UPDATE/DELETE）- 返回结果元数据
local result = db.exec(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
print(result.affected_rows)

-- 查询（SELECT）- 返回行表数组
local users = db.query(conn, "SELECT * FROM users WHERE active = 1")
for _, user in ipairs(users) do
    print(user.id, user.name)
end

-- 参数化查询（防止 SQL 注入）
local results = db.query(conn, "SELECT * FROM users WHERE name = ?", "alice")
db.exec(conn, "INSERT INTO users (name) VALUES (?)", "bob")

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
db.exec(conn, "INSERT INTO users (name) VALUES (?)", "alice")

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
db.exec(conn, "INSERT INTO users (name) VALUES ($1)", "alice")  -- PostgreSQL 使用 $1, $2 等

db.close(conn)
```

### 数据库 API 概览

| 函数 | 描述 | 返回值 |
|------|------|--------|
| `db.open(path_or_config)` | 打开连接 | 连接句柄 |
| `db.close(conn)` | 关闭连接 | - |
| `db.query(conn, sql, ...)` | 执行 SELECT（可带参数） | 行表数组 |
| `db.exec(conn, sql, ...)` | 执行 INSERT/UPDATE/DELETE（可带参数） | 结果表（`affected_rows`、`last_insert_id`） |
| `db.query_params(conn, sql, ...)` | 与 `db.query` 行为一致 | 行表数组 |
| `db.exec_params(conn, sql, ...)` | 与 `db.exec` 行为一致 | 结果表（`affected_rows`、`last_insert_id`） |
| `db.escape(str)` | 转义 SQL 字符串 | 转义后的字符串 |

### 共享字典（`lunet.ngx_shared`）— Linux / macOS

受 nginx 启发的共享字典，由 Rust FFI 库支撑。这**不**依赖 nginx 或 OpenResty——
API 风格类似 `ngx.shared.DICT`，便于熟悉 OpenResty 的开发者快速上手，但不复制
任何 OpenResty 的未定义行为。纯可选扩展。

**构建**（需要 Rust 1.85+ / 2024 edition）：
```bash
xmake build-ngx-shared   # 等同于: cd ext/ngx_shared && cargo build --release
```

**使用示例**：
```lua
local shared = loadfile("ext/ngx_shared/ngx_shared.lua")()

local cache = shared.open("my_cache", 1024 * 1024)  -- 1 MiB

cache:set("key", "value")
cache:set("hits", 0)
cache:incr("hits", 1, 0)        -- 原子自增（init=0 时自动创建）
cache:set("session", "tok", 30) -- 30 秒后过期

cache:add("lock", "worker-1")   -- 仅在 key 不存在时设置
cache:replace("lock", "w2")     -- 仅在 key 存在时更新

cache:flush_all()
local evicted = cache:flush_expired()

print(cache:capacity(), cache:free_space())

-- 句柄由 GC 自动管理（ffi.gc 终结器）；如需立即释放可显式关闭。
-- 共享区域本身的生命周期不受单个句柄关闭影响。
cache:close()
```

**架构**：每个命名字典使用一个 `mmap(MAP_ANONYMOUS|MAP_SHARED)` 匿名映射区域；
所有状态均在该区域内（无堆分配持久数据）；FNV-1a 开放地址哈希表；
bump 分配器；单自旋锁。同一进程内以相同名称打开的多个句柄共享同一区域。

### JSON（`lunet.jsonic`）— Linux / macOS

dkjson 兼容的 `encode`/`decode`/`null` API。解码由 Rust FFI 封装
[jsonic](https://github.com/g1mv/jsonic)（MIT / Apache-2.0，无运行时依赖）
实现——完整署名见 `ext/jsonic/NOTICE.md`。`jsonic` 本身只做解析；`encode()`
是纯 Lua 实现，无任何依赖。

**构建**（需要 Rust 1.85+ / 2024 edition）：
```bash
xmake build-jsonic   # 等同于: cd ext/jsonic && cargo build --release
```

**使用示例**：
```lua
local json = loadfile("ext/jsonic/jsonic.lua")()

local value, pos, err = json.decode('{"a":1,"b":[true,null]}')
-- value = { a = 1, b = { true, json.null } }

local str = json.encode({ a = 1, b = { true, json.null } })
-- str = '{"a":1,"b":[true,null]}'

json.encode({ a = 1 }, { indent = true, keyorder = { "a" } })
```

**Maelstrom 测试平台**:[`ext/jsonic/maelstrom/`](ext/jsonic/maelstrom/README-CN.md)
将 jsonic 演示作为 Maelstrom(Jepsen)节点运行 —— Docker arm64、无卷挂载、
仅回环 —— 通过 `make -C ext/jsonic/maelstrom test` 执行。

### 图数据库（`lunet.graphlite`）— Linux / macOS

基于 [GraphLite](https://github.com/GraphLite-AI/GraphLite) 的 ISO GQL
(Graph Query Language) 图数据库，GraphLite 是一个用 Rust 编写的可嵌入图数据库。
与 `ngx_shared`/`jsonic` 不同（它们的 Rust 源码在仓库内），GraphLite 没有官方
平台包，因此其 `graphlite-ffi` crate 是从固定的上游 commit 按需由 xmake 克隆
构建的。`lunet-graphlite` C 模块（`ext/graphlite/`）在运行时通过
`dlopen`/`LoadLibrary` 动态加载生成的库，并像 SQLite3 驱动一样将调用分派到
libuv 工作线程，具有相同的协程 yield/resume 语义。

**构建**（需要 Rust 1.87+ / 2024 edition，通过 `rustup` 自动获取）：
```bash
xmake build-graphlite   # 克隆固定 commit 的 GraphLite、构建 Rust FFI cdylib、
                         # 编译 lunet-graphlite C 桩代码
```

**使用示例**：
```lua
local gl = require("lunet.graphlite")

local conn, err = gl.open({ path = "/tmp/mydb" })
local session, err = gl.create_session(conn, "admin")

gl.query(conn, session, "CREATE SCHEMA IF NOT EXISTS /example")
gl.query(conn, session, "SESSION SET SCHEMA /example")
gl.query(conn, session, "CREATE GRAPH IF NOT EXISTS social")
gl.query(conn, session, "SESSION SET GRAPH social")

gl.query(conn, session, "INSERT (:Person {name: 'Alice', age: 30})")
local result, err = gl.query(conn, session, "MATCH (p:Person) RETURN p.name, p.age")

gl.close_session(conn, session)
gl.close(conn)
```

完整流程（模式/图 DDL、插入、模式匹配、过滤、聚合）见
[`examples/10_graphlite_gql.lua`](examples/10_graphlite_gql.lua)。

## 安全性：零开销追踪

使用 `xmake build-debug` 构建可启用协程引用追踪和栈完整性检查。运行时会在检测到泄漏或栈污染时触发断言并崩溃。

## 开发者工作流

xmake 是标准构建系统。没有 Makefile。所有任务定义在 `xmake.lua` 中。

| 任务 | 描述 |
|------|------|
| `xmake lint` | C 安全代码检查 |
| `xmake check` | luacheck 静态分析 |
| `xmake test` | 单元测试（busted） |
| `xmake build-release` | 优化的发布构建 |
| `xmake build-debug` | 启用追踪的调试构建 |
| `xmake examples-compile` | 示例编译/语法检查 |
| `xmake sqlite3-smoke` | SQLite3 示例冒烟测试 |
| `xmake build-ngx-shared` | 构建 ngx_shared Rust 扩展 |
| `xmake ngx-shared-smoke` | 构建 ngx_shared 并运行冒烟测试 |
| `xmake build-jsonic` | 构建 jsonic Rust 扩展 |
| `xmake jsonic-smoke` | 构建 jsonic 并运行冒烟测试 |
| `xmake build-graphlite` | 构建 GraphLite Rust 扩展（克隆 + cargo build + C 桩代码） |
| `xmake graphlite-smoke` | 构建 GraphLite 扩展并运行示例冒烟测试 |
| `xmake stress` | 带追踪的并发压力测试 |
| `xmake ci` | 本地 CI 一致性检查（lint + 构建 + 示例 + sqlite3 冒烟） |
| `xmake preflight-easy-memory` | EasyMem + ASan 预检门控 |
| `xmake release` | 完整发布门控（lint + test + stress + 预检 + 构建） |

完整任务目录和推荐工作流请参见 **[docs/WORKFLOW-CN.md](docs/WORKFLOW-CN.md)**。

### 快速测试

```bash
xmake test    # 单元测试
xmake stress  # 带追踪的并发负载测试
xmake ci      # 完整的本地 CI 一致性检查
```

## 许可证

MIT
