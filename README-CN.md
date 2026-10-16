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
| **hack 核心** | 你开发 Lunet 本身，或想要最小化功能构建 | xmake + 系统开发库 | `make init`，然后 [docs/XMAKE_INTEGRATION-CN.md](docs/XMAKE_INTEGRATION-CN.md) |

## 获取运行时

**最省事的办法：直接下载预构建发布包。** 无需任何工具链 —— 每个
[发布](https://github.com/lua-lunet/lunet/releases) 都会发布自包含压缩包
（`lunet-linux-amd64.tar.gz`、`lunet-linux-arm64.tar.gz`、
`lunet-macos.tar.gz`、`lunet-windows-amd64.zip`），内含 `lunet-run` 与全部
扩展模块的预构建二进制：

```bash
TAG=v0.10.0
curl -fsSLO "https://github.com/lua-lunet/lunet/releases/download/${TAG}/lunet-macos.tar.gz"
tar -xzf lunet-macos.tar.gz
./lunet-run path/to/app.lua
```

（Windows 用户：下载并解压 `lunet-windows-amd64.zip`。）共享库引用由你
操作系统已有的运行时包满足 —— 在 Debian/Ubuntu 上：`libluajit-5.1-2
libuv1 zlib1g`，再为你实际 `require()` 的每个扩展装一个运行时包（例如
SQLite 驱动装 `libsqlite3-0`，`lunet.httpc` 装 `libcurl4`）。完整的依赖
清单与平台说明见：[docs/RELEASE-LAYOUT-CN.md](docs/RELEASE-LAYOUT-CN.md)。

压缩包内容一览：

| 文件 | 是什么 |
|------|--------|
| `lunet-run` | 独立可执行文件 —— 直接运行 Lua 应用 |
| `lunet.so` | `require("lunet")` 使用的核心共享库 |
| `lunet/` | 预构建扩展模块：`sqlite3` 驱动为 `sqlite3core.so` + 其 `sqlite3.lua` 加载器（完整参考：`ext/sqlite3/SQLITE-CN.md`）、`mysql` / `postgres` 驱动 + 事务包装、`httpc`、Rust 扩展（`lnt_shared`、`jsonic`、`paxe`、`sodium`）的 `.so` / `.dylib` / `.dll` —— 规范清单见 [docs/RELEASE-LAYOUT-CN.md](docs/RELEASE-LAYOUT-CN.md) |
| `types/` | 用于编辑器补全的 LuaCATS 注解 |
| `*.md` | 随附文档 |

你也可以从源码构建、深入底层细节 —— 见
[docs/XMAKE_INTEGRATION-CN.md](docs/XMAKE_INTEGRATION-CN.md)。当目标环境
不允许使用预构建二进制时必须走这条路；除此之外请直接使用发布压缩包。

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

## 示例：MCP-SSE 服务器

仓内最小入门示例见 [`examples/mcp_openalex_sse/`](examples/mcp_openalex_sse/) —— 一个通过 `lunet.httpc` 调用 [OpenAlex](https://openalex.org/) 学术 API 的 SSE 传输 MCP 服务器，无数据库、无文件系统状态。

[lunet-mcp-sse](https://github.com/lua-lunet/lunet-mcp-sse) 是一个更完整的 MCP（Model Context Protocol）服务器，带 Tavily 网络搜索，展示：

- **SSE 传输** —— 用于实时流式的 Server-Sent Events
- **HTTP 上的 JSON-RPC** —— 有状态的会话管理
- **外部 API 调用** —— 通过 curl 集成 Tavily 搜索
- **零开销追踪** —— 生产环境零代价的调试日志

**为什么 MCP 服务器选 lunet？**

MCP 服务器常常以 sidecar 进程部署。Lunet 的依赖（libuv、LuaJIT）都是成熟、稳定、有 Debian LTS 支持的库——没有 npm/pip 的反复变更，也不用没完没了地打安全补丁。

| 实现 | 镜像大小 | 运行内存 |
|----------------|------------|----------------|
| **lunet-mcp-sse** | **171 MB** | **7 MB** |
| tavily-mcp (Node.js) | 420 MB | 18 MB |
| tavily-mcp (Bun) | 382 MB | 14 MB |
| FastMCP (Python) | 367 MB | 28 MB |

```bash
# 快速开始
curl -L -o lunet-mcp-sse.tar.gz \
  https://github.com/lua-lunet/lunet-mcp-sse/releases/download/nightly/lunet-mcp-sse-linux-arm64.tar.gz
tar -xzf lunet-mcp-sse.tar.gz
echo "TAVILY_API_KEY=your_key" > .env
./run.sh
```

[`examples/realworld/README-CN.md`](examples/realworld/README-CN.md) 是路标：完整的 RealWorld "Conduit" 实现位于
[lua-lunet/realworld-lua](https://github.com/lua-lunet/realworld-lua)，演示如何
用 Lunet 构建更典型的应用，同时保持更小的内存占用与更快的启动时间。

## How-To 示例

先构建运行器：

```bash
xmake build-release
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)
```

如果你下载的是预构建的发布压缩包而不是自己构建，把 `LUNET_BIN` 指向压缩包里的
`lunet-run` 即可：旁边的 `lunet/` 目录已经把下表中「需要」列的每个扩展都作为预构
建二进制一并携带 —— 只有从源码构建时才需要 `xmake build <target>`。

| # | 示例 | 演示内容 | 需要 | 运行 |
|---:|---------|---------------|----------|-----|
| 01 | [`examples/01_http_json.lua`](examples/01_http_json.lua) | 极简 HTTP 服务器，返回 JSON | 核心（`lunet`、`lunet.socket`） | `"$LUNET_BIN" examples/01_http_json.lua` |
| 02 | [`examples/02_http_routing.lua`](examples/02_http_routing.lua) | 带路径 `:params` 的微型路由 | 核心（`lunet`、`lunet.socket`） | `"$LUNET_BIN" examples/02_http_routing.lua` |
| 03 | [`examples/03_db_sqlite3.lua`](examples/03_db_sqlite3.lua) | SQLite3 CRUD + `(rw, ro)` 读写拆分（读在循环线程内联执行） | `xmake build lunet-sqlite3` | `"$LUNET_BIN" examples/03_db_sqlite3.lua` |
| 04 | [`examples/04_db_mysql.lua`](examples/04_db_mysql.lua) | MySQL CRUD + 预处理语句（`?`） | `xmake build lunet-mysql` + MySQL 服务器 | `"$LUNET_BIN" examples/04_db_mysql.lua` |
| 05 | [`examples/05_db_postgres.lua`](examples/05_db_postgres.lua) | Postgres CRUD + 预处理语句（`$1`） | `xmake build lunet-postgres` + Postgres 服务器 | `"$LUNET_BIN" examples/05_db_postgres.lua` |
| 08 | [`examples/08_lnt_shared.lua`](examples/08_lnt_shared.lua) | 经 Rust FFI 的 lunet 风格共享字典 | `xmake build-lnt-shared` | `"$LUNET_BIN" examples/08_lnt_shared.lua` |
| 09 | [`examples/09_jsonic_demo.lua`](examples/09_jsonic_demo.lua) | 经 Rust FFI 的 dkjson 风格 JSON 编解码 | `xmake build-jsonic` | `"$LUNET_BIN" examples/09_jsonic_demo.lua` |
| 10 | [`examples/mcp_openalex_sse/`](examples/mcp_openalex_sse/) | **规范级微型 MCP 服务器**：SSE 传输 + 经 `lunet.httpc` 的 OpenAlex API，无数据库、仅回环 | `xmake build lunet-httpc` + `.env` 中的 `OPEN_ALEX_API_KEY` | `"$LUNET_BIN" examples/mcp_openalex_sse/main.lua` |

## 核心模块

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

TCP 数据套接字（`accept` 与 `connect` 的返回结果）默认启用 `TCP_NODELAY`：本运行时的目标负载是
小型单次写入的请求/响应流量，Nagle 在这种场景下只会带来 delayed-ACK 尾延迟，没有任何收益。
对特定套接字重新启用 Nagle（多小帧写协议）用 `socket.set_nodelay(handle, false)`；
`socket.set_nodelay(handle, true)` 再关回去。Unix 套接字忽略该设置。

```lua
socket.set_nodelay(conn, false)  -- 对该套接字重新启用 Nagle
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

-- 打开：返回两个连接 —— rw（worker 池）+ ro（读在循环线程内联执行）。
-- 调用对按路径缓存；完整参考见 ext/sqlite3/SQLITE-CN.md
local rw, ro, err = db.open({ path = "myapp.db" })
if not rw then error(err) end
assert(db.exec(rw, "PRAGMA journal_mode=WAL"))

-- 执行语句（INSERT/UPDATE/DELETE）- 返回结果元数据
local result = db.exec(rw, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
print(result.affected_rows)

-- 通过只读句柄查询（SELECT）- 返回行表数组
local users = db.query(ro, "SELECT * FROM users WHERE active = 1")
for _, user in ipairs(users) do
    print(user.id, user.name)
end

-- 参数化查询（防止 SQL 注入）
local results = db.query(ro, "SELECT * FROM users WHERE name = ?", "alice")
db.exec(rw, "INSERT INTO users (name) VALUES (?)", "bob")

-- 缓存对经 destroy(path) 关闭；open_raw() 打开未缓存的一对，
-- 其句柄经 db.close() 逐个关闭
db.destroy("myapp.db")
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
| `db.open(config)` | 打开连接：sqlite3 返回按路径缓存的 `(rw, ro)` 对；postgres/mysql 返回单个连接（可用 `pool_size` 池化，默认 1） | 连接句柄 |
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

## 调试

Lunet 对运行期崩溃有分层的调试策略。请按顺序使用——每一级都更昂贵，但给出更多细节。

### 快速参考

| 层级 | 工具 | 能捕获什么 | 构建命令 |
|-------|------|----------------|---------------|
| 1 | 领域追踪 | 逻辑错误、操作序列 | `xmake f --lunet_trace=y --lunet_verbose_trace=y` |
| 2 | 内存追踪 + EasyMem | UAF、双重释放、泄漏、分配器完整性 | `xmake f --lunet_trace=y`（自动启用 EasyMem） |
| 3 | Address Sanitizer + EasyMem | 编译器级内存错误 + 分配器诊断 | `xmake f -m debug --asan=y` |
| 4 | lldb / 核心转储 | 寄存器级检查、完整回溯 | `lldb -- ./build/.../lunet-run app.lua` |

### 领域追踪（第 1 层）

每个模块（socket、timer、fs、udp、signal）都有 `*_TRACE_*` 宏，输出到 stderr。启用详细追踪构建：

```bash
xmake f -c -y --lunet_trace=y --lunet_verbose_trace=y
xmake build lunet-bin
./build/.../lunet-run app.lua 2> trace.log
```

当追踪日志戛然而止时，崩溃发生在最后打印的行与下一个操作之间。用它来锁定是哪个回调、哪一行。

### Address Sanitizer（第 3 层）

ASan 是对付内存损坏 bug 最有效的工具。它为每一次内存访问插桩，并带精确源码位置地捕获 use-after-free、缓冲区溢出和栈损坏：

```bash
xmake f -c -y -m debug --lunet_trace=y --asan=y
xmake build lunet-bin
./build/.../lunet-run app.lua 2> asan.log
```

`--asan=y` 时，Lunet 还会同时启用带诊断模式的 EasyMem 后端（`LUNET_EASY_MEMORY_DIAGNOSTICS`），分配器级完整性检查与性能画像与 ASan 并行运行。

ASan 输出到 stderr。进程以 `Abort trap: 6` 而不是 `Segmentation fault: 11` 退出。在日志里找 `ERROR: AddressSanitizer:`。

#### 完整 LuaJIT + Lunet ASan（Debian Trixie 源码包）

要同时插桩 Lunet 与 LuaJIT（不只是 Lunet 的 C 代码），构建 Debian Trixie 使用的 OpenResty LuaJIT 源码包，并把 Lunet 链接到它：

```bash
xmake luajit-asan
xmake build-debug-asan-luajit
xmake repro-50-asan-luajit
```

这些辅助目标现在自动继承 EasyMem，因为它们配置了 `--asan=y --lunet_trace=y`。

这里使用 Debian 源码包 `luajit_2.1.0+openresty20250117-2`，并把本地 ASan 版 LuaJIT 装到 `.tmp/luajit-asan/install/2.1.0+openresty20250117/`。

版本钉子配置在 `xmake.lua` 的选项里（`luajit_snapshot`、`luajit_debian_version`）。覆盖：

```bash
xmake f --luajit_snapshot=2.1.0+openresty20250117 --luajit_debian_version=2.1.0+openresty20250117-2 -y
```

#### macOS / Xcode：符号化的 ASan 输出

在 macOS 上，确保 Xcode 工具链就绪，ASan 报告才会带文件/行号符号：

```bash
xcode-select -p
xcrun --find clang
xcrun --find llvm-symbolizer
export ASAN_SYMBOLIZER_PATH="$(xcrun --find llvm-symbolizer)"
export ASAN_OPTIONS="abort_on_error=1,halt_on_error=1,fast_unwind_on_malloc=0,detect_leaks=0"
```

如果 `xmake luajit-asan` 报 `missing: export MACOSX_DEPLOYMENT_TARGET=XX.YY`，设置：

```bash
export MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion | awk -F. '{print $1 "." $2}')"
```

#### ASan 优先的崩溃追捕（强制快速退出）

不要只靠边界追踪去推断故障位置。先让 LuaJIT/Lunet 在 ASan 下立刻崩：

```bash
xmake build-debug-asan-luajit
xmake repro-50-asan-luajit
```

如果 bug 对时序敏感，多跑几轮：

```bash
ITERATIONS=100 REQUESTS=100 CONCURRENCY=8 WORKERS=8 xmake repro-50-asan-luajit
```

为了在隔离 yield/resume 记账类 bug 时降低 JIT 侧的非确定性，可以在 repro 的 Lua 入口里关掉 JIT：

```lua
local ok, jit = pcall(require, "jit")
if ok and jit then jit.off() end
```

这让执行留在解释器模式，常能让协程/状态机类故障在 ASan 下更快复现。

### 协程 Resume 追踪

`lunet_co_resume()` 包装器会在每次 `lua_resume` 前后记录 `[CO_TRACE] RESUME` / `[CO_TRACE] RESUMED`（启用详细追踪时）。它证明崩溃是在 Lua VM 内部，还是在其周围 C 代码里。

### 等待/Resume 记账断言（仅调试构建）

`LUNET_TRACE=ON` 时，socket 与 UDP 路径会为以下操作跟踪等待/resume 序号与在途状态：

- socket：`accept`、`read`、`write`
- udp：`recv`

任何非法迁移（重复等待、没有等待就 resume、resume 序号越过等待序号）会打印 `BK_FAIL` 并立刻触发断言。它把协程泵/状态机记账类 bug 在第一次违规时当场抓住，而不需要从边界追踪里推断。

### 零开销发布保证

所有记账、追踪计数器、金丝雀和断言都只在 `LUNET_TRACE` 下编译。发布构建（`--lunet_trace=n`）把这些检查完全编译掉，调试插桩不给运行期留下任何代价。

### 常见崩溃签名：回调里的 `lua_rawgeti`

如果崩溃发生在 libuv 回调里的 `lua_rawgeti`，通常意味着用于注册表操作的 `lua_State*` 无效（悬空或已损坏）。不要把短命的协程 `lua_State*` 指针存进长寿命句柄；注册表访问使用拥有它的主状态，等待中的协程用 coref 跟踪。

### 内存追踪

`LUNET_TRACE` 启用时，所有经 `lunet_alloc()` / `lunet_free()` 的分配都带金丝雀头与释放投毒。trace 构建也会自动启用 EasyMem，提供分配器级完整性检查和内存可视化。关机时 `lunet_mem_assert_balanced()` 检查泄漏。在所有 lunet C 代码里请用 `lunet_alloc` / `lunet_free`，不要裸用 `malloc` / `free`。

## 下游集成

- **[集成指南](docs/XMAKE_INTEGRATION-CN.md)** —— 构建 Lunet 并集成进你的项目（对新手友好）
- **[Badge 指南](docs/BADGES-CN.md)** —— 在项目 README 中添加徽章（构建状态、Lunet 版本）
- **[EasyMem 报告](docs/EASY_MEMORY_REPORT-CN.md)** —— 性能画像发现与下一步内存建议

## 许可证

MIT
