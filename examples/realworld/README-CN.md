# Lunet 演示项目一览

Lunet 的理念是*不需要*全家桶：一个很小的运行时，按服务真正需要的部件拼装，
仅此而已。而这里收集的演示证明了它能做一整圈内的事情 —— 原始 HTTP、四个
SQL 驱动、加密数据报、MCP 服务器、嵌入 C 宿主程序，以及一个完整的 RealWorld
应用。设计上的「少」，不是能力上的「少」。

## 演示应用

| # | 应用 | 它是什么 | 位置 |
|---|------|----------|------|
| 1 | twelve-dollar-server-challenge | 面向资源受限主机的现实版 Feed API（SQLite） | [lua-lunet/twelve-dollar-server-challenge](https://github.com/lua-lunet/twelve-dollar-server-challenge) |
| 2 | realworld-lua | RealWorld "Conduit" 应用 | [lua-lunet/realworld-lua](https://github.com/lua-lunet/realworld-lua) |
| 3 | lunet-mcp-sse | 以 Docker 镜像交付的生产级 SSE 传输 MCP 服务器 | [lua-lunet/lunet-mcp-sse](https://github.com/lua-lunet/lunet-mcp-sse) |
| 4 | lunet-backproxy | 面向 DMZ 拓扑的纯出站反向代理 | [lua-lunet/lunet-backproxy](https://github.com/lua-lunet/lunet-backproxy) |
| 5 | examples/mcp_openalex_sse | 本仓库内完整的 MCP-over-SSE 演示 | [examples/mcp_openalex_sse](../mcp_openalex_sse/) |

### 1. twelve-dollar-server-challenge

一个 Feed API —— 读信息流、发帖、点赞 —— 由进程内 SQLite 支撑，为一台被
限制在 1 vCPU、2 GB 内存的宿主而写：那正是该挑战每年十二美元租用的机器。
它是本目录的典型代表：整个提交就是应用逻辑（`server.lua` 加上 `app/` 的路
由、JWT 与 SQLite 访问），而效率与体积正是 lunet 打算发光的地方。在一台
macOS arm64 开发机上实测，运行该提交 `server.lua` 的 lunet 运行时，**启动
后常驻内存 3.7 MB**，**25 次顺序回环请求后稳定在 4.1 MB**（`ps -o rss=` 读
数分别为 3,712 KB 与 4,160 KB；单客户端、三行种子的数据库）。这些是开发机
上的条件，不是计分环境的条件 —— 挑战自己的 1 vCPU / 2 GB 计分机才是权威环
境：该提交的 README 报告在那里以 18 MB 的峰值 RSS 扛住了 2,500 个虚拟用户
整整五分钟的基准测试。

### 2. realworld-lua

RealWorld "Conduit" 应用 —— 注册、认证、文章、评论与关注，跑在 PostgreSQL
上 —— 作为一个普通、典型的 Web 应用。在 RealWorld 演示里，资源占用这件事
容易被忽视，所以它的
[README 里有一张实测对比表](https://github.com/lua-lunet/realworld-lua#resource-footprint)，对照同一规范的
Node.js 与 Python/Django 实现；请直接看那张表，不要相信转述。

### 3. lunet-mcp-sse

一个讲 SSE 传输的生产级 MCP 服务器，以 Docker 镜像发布，可原样放进 AI 助手
的既有部署。它的 README 是尺寸数据的出处，而这些数据说的是开销：171 MB 的
镜像、约 7 MB 的常驻运行时，对照它所列出的 Node.js、Bun 与 Python MCP 实现
的 367–420 MB 镜像与 14–28 MB 运行时。提供容器镜像，是为了让服务器能不加
改动地落进现有部署。

### 4. lunet-backproxy

一种受保护区域完全没有入站路径的反向代理：内部 worker 主动*向外*连到 DMZ
里的 broker —— broker 坐在 nginx/OpenResty 之后 —— HTTP 请求经由这些出站
连接隧道送达。这一点上它是独一无二地安全，遵循 QMail 学派：一个进程，一个
专注的职责，横跨信任边界。作为演示，它证明了灵活性：同一个能写 HTTP 处理
器的运行时，也能胜任安全拓扑中的角色。

### 5. examples/mcp_openalex_sse

本地的、仓库内的完整演示：一个讲 SSE 传输的 MCP 服务器，带三个由免费的
OpenAlex 学术 API 支撑的工具，只听回环，无数据库。它是那个「克隆即跑」的
示例 —— 克隆本仓库、构建运行时、把 OpenAlex API 密钥放进 `.env` 文件，用
构建好的 `lunet-run` 执行 `examples/mcp_openalex_sse/main.lua` 即可；确切
命令见它的 [README](../mcp_openalex_sse/README-CN.md)。

## 仓库内演示文件

`examples/` 目录本身就是仓库内的索引。每一项都是一个小巧、自包含的演示，
展示运行时的一个侧面：

| 条目 | 演示内容 |
|------|----------|
| `01_http_json.lua` | 在 `lunet.socket` 上手写 HTTP/1.1 与 JSON 转义 —— 不用任何库的 JSON API |
| `02_http_routing.lua` | 原始套接字上带 `:param` 模式的手写路由表 |
| `03_db_sqlite3.lua` | 内置 SQLite3 驱动：建表与基本 CRUD |
| `04_db_mysql.lua` | MySQL 驱动连本地服务器（环境变量配置） |
| `05_db_postgres.lua` | 基于 libpq 的 PostgreSQL 驱动 |
| `06_paxe_encryption.lua` | PAXE 数据报加密：seal/open、每套接字保护 |
| `07_paxe_stress.lua` | PAXE 压力测试：跨 64 字节缝的载荷尺寸、故意的故障注入 |
| `08_http.lua` | `lunet.http` + `http_router` + `lnt_shared` 的接线，一个可运行文件讲完 |
| `09_jsonic_demo.lua` | jsonic 扩展：dkjson 风格 API 之下的 Rust JSON 解码 |
| `10_db_prepared.lua` | SQLite 预编译语句 |
| `mcp_openalex_sse/` | 完整的 MCP-over-SSE 演示（见上文） |
| `realworld/` | 本目录：通往 RealWorld 应用的路标 |
| `sdk_embed/` | 将 lunet 运行时嵌入带内嵌脚本的 C 宿主程序 |
