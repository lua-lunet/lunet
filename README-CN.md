# Lunet

基于协程的高性能 LuaJIT 网络库，构建于 libuv 之上。

[English Documentation](README.md)

[![EasyMem](https://img.shields.io/badge/EasyMem-easy__memory-27272d?style=flat&logo=github&logoColor=white)](https://github.com/EasyMem/easy_memory)

> 本项目基于 [夏磊 (Xia Lei)](https://github.com/xialeistudio) 的 [xialeistudio/lunet](https://github.com/xialeistudio/lunet)。详见他的精彩文章：[Lunet：高性能协程网络库的设计与实现](https://www.ddhigh.com/2025/07/12/lunet-high-performance-coroutine-network-library/)。

Lunet 最初的用途是编写**微型 localhost MCP 服务器** —— 运行在 LLM 客户端旁、回环地址上的 Model Context Protocol 工具：空闲时只占个位数 MB 内存，瞬间启动。这至今仍是首页用例。长篇理念阐述请阅读：**[Lunet 的 Talos、Ethos 与無為](docs/PHILOSOPHY-CN.md)**。

## 三种使用 Lunet 的方式

| 路径 | 适合谁 | 需要什么 | 从这里开始 |
|------|--------|----------|------------|
| **运行 Lua** | 你写 Lua 应用；不想碰 C 工具链 | 对应 OS 的发布压缩包 | [发布页](https://github.com/lua-lunet/lunet/releases) |
| **打包一体机** | 你要交付单一自包含可执行文件 —— 你的 `main()` + Lunet + 你的应用 | 发布版 SDK + 一个 C 编译器 | [docs/EMBEDDING-CN.md](docs/EMBEDDING-CN.md) |
| **hack 核心** | 你开发 Lunet 本身，或想要最小化功能构建 | xmake + 系统开发库 | [docs/XMAKE_INTEGRATION-CN.md](docs/XMAKE_INTEGRATION-CN.md) |

## 安全姿态：默认仅回环

Lunet 拒绝把监听器绑定到 `127.0.0.1`、`::1` 或 Unix socket 以外的地址 —— **默认没有远程安全漏洞**。要对外暴露服务，请在前面放一个久经考验的 sidecar（nginx、OpenResty、Caddy、Envoy，由管理员选择），让协议拆分攻击死在代理层而不是你的 Lua 协程里。在唯一入口是加固云代理（清洗畸形流量、吸收 DDoS）的私有网络中，绑定所有网卡可以是安全的 —— 但 Lunet 要求你用显式的 `--dangerously-skip-loopback-restriction` 标志郑重声明这一点。详见 [docs/SECURITY_ARCHITECTURE-CN.md](docs/SECURITY_ARCHITECTURE-CN.md)。

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
  - `lunet.lnt_shared` - lunet 风格的共享字典，通过 Rust FFI 实现（`xmake build-lnt-shared`）
- **JSON**（可选 Rust 扩展，Linux/macOS）：
  - `lunet.jsonic` - dkjson 风格的编解码；解码通过 Rust FFI 封装 [jsonic](https://github.com/g1mv/jsonic)（`xmake build-jsonic`）

只构建一个数据库驱动，而不是全部。没有未使用的依赖。不需要为从未使用的库打安全补丁。

入门（完整构建流程、配置档位、集成方式）：
- **[docs/PHILOSOPHY-CN.md](docs/PHILOSOPHY-CN.md)**（长篇理念阐述）
- **[docs/XMAKE_INTEGRATION-CN.md](docs/XMAKE_INTEGRATION-CN.md)**
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
# 默认 SQLite 构建（同时构建 lunet-static SDK 静态库和 sdk-api-test）
xmake build-release

# 调试模式构建（启用追踪）
xmake build-debug
```

LuaJIT、libuv 和 zlib 是必需依赖；每个驱动只增加自己的客户端库。发布档位默认会剥离 EasyMem。若需 EasyMem 诊断，请使用 debug/ASan 档位。

## 示例应用

最小入门示例请见 [`examples/mcp_openalex_sse/`](examples/mcp_openalex_sse/) —— 一个通过 `lunet.httpc` 调用 [OpenAlex](https://openalex.org/) 学术 API 的 SSE 传输 MCP 服务器，无数据库、无文件状态。

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

**注意**：三种驱动内部均使用原生预处理语句。参数通过驱动原生函数（`sqlite3_bind_*`、`mysql_stmt_bind_param`、`PQexecParams`）自动绑定，从根本上消除 SQL 注入风险。本项目有意不提供 `db.escape`：手工转义既无必要，也永远不如参数绑定安全。

### 事务

使用你自己持有的连接句柄，像执行普通语句一样执行事务控制语句：

```lua
db.exec(conn, "BEGIN")
local ok, err = pcall(function()
    db.exec(conn, "DELETE FROM nodes WHERE path = $1", dst)
    db.exec(conn, "UPDATE nodes SET path = $1 WHERE path = $2", dst, src)
end)
db.exec(conn, ok and "COMMIT" or "ROLLBACK")
```

需要注意两点：

- **带绑定参数的语句必须是单条命令。** 这是 libpq / MySQL 扩展协议的行为，并非
  Lunet 的限制。**不带**参数的语句可以包含多条以 `;` 分隔的命令，但只会返回最后
  一条命令的行数据与 `affected_rows`。
- **事务属于连接句柄，而不属于协程。** 事务中的所有语句必须使用同一个 `conn`。
  如果应用层使用连接池，请在整个事务期间固定同一个句柄——每次调用都从池中租借
  连接的做法会把 `BEGIN` 与 `COMMIT` 分散到不同会话上。在提交之前，不要让其他
  协程使用该句柄。

### 共享字典（`lunet.lnt_shared`）— Linux / macOS

lunet 风格的共享字典，由 Rust FFI 库支撑。纯可选扩展。

**构建**（需要 Rust 1.85+ / 2024 edition）：
```bash
xmake build-lnt-shared   # 等同于: cd ext/lnt_shared && cargo build --release
```

**使用示例**：
```lua
local lnt = loadfile("ext/lnt_shared/lnt_shared.lua")()

local cache = lnt.store("my_cache", 1024 * 1024)  -- 1 MiB

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
| `xmake build-lnt-shared` | 构建 lnt_shared Rust 扩展 |
| `xmake lnt-shared-smoke` | 构建 lnt_shared 并运行冒烟测试 |
| `xmake build-jsonic` | 构建 jsonic Rust 扩展 |
| `xmake jsonic-smoke` | 构建 jsonic 并运行冒烟测试 |
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
