# mcp-openalex —— 微型 localhost MCP 服务器

[English Documentation](README.md)

Lunet 的规范示例：一个使用 Streamable HTTP 传输（MCP 规范 2025-03-26）的
[MCP](https://modelcontextprotocol.io/) 服务器，提供三个由免费
[OpenAlex](https://openalex.org/) 学术 API 支撑的工具：

| 工具 | 功能 | 费用（每日 $1 免费额度） |
|------|------|--------------------------|
| `openalex_search_works` | 在约 2.5 亿篇论文中做全文检索 | 每次约 $0.001 |
| `openalex_get_work` | 按 OpenAlex ID / DOI / URL 获取单篇元数据与摘要 | 免费 |
| `openalex_search_authors` | 按姓名检索作者，含机构与引用数 | 每次约 $0.001 |

本示例刻意保持"无遗留"：只讲 Streamable HTTP，以此保持精小、适合作为起
步模板。请求分帧由 `lunet.http` 的连接循环提供（分块主体、流水线、大小限
制），编解码用 `lunet.jsonic` —— 没有手写的 HTTP 解析。无数据库、无文件状
态、仅回环。唯一的出站流量是经 `lunet.httpc`（libcurl）发往
`api.openalex.org` 的 HTTPS —— 进程空闲时只占个位数 MB 内存，这正是用
Lunet 而不是更大运行时来跑 MCP 服务器的意义。

需要同时展示遗留 HTTP+SSE 传输（MCP 规范 2024-11-05）与 Streamable HTTP
的完整演示——initialize/会话处理、两种响应模式、分块编码、流水线——请看
[lua-lunet/lunet-mcp](https://github.com/lua-lunet/lunet-mcp)：一个基于相同
模块构建的更完整的 Tavily MCP 服务器。

## 配置

1. 在 <https://openalex.org/settings/api> 免费申请 API key（约一分钟），
   并写入你运行服务器所在目录的 `.env`：

   ```
   OPEN_ALEX_API_KEY=你的key
   ```

2. 构建运行器和 HTTP 客户端模块（只需一次）：

   ```bash
   xmake build-release
   xmake build lunet-httpc
   ```

## 运行

```bash
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" examples/mcp_openalex_sse/main.lua
# mcp-openalex listening on http://127.0.0.1:39281/mcp
```

把 MCP 客户端指向 `http://127.0.0.1:39281/mcp`（Streamable HTTP）。
`.env`（或环境变量）中的 `MCP_PORT` 可修改端口。

## 用 curl 试一试

先 initialize —— 响应头里带 `Mcp-Session-Id`，后续每次调用都要复用它：

```bash
curl -s -D /dev/stdout http://127.0.0.1:39281/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
# HTTP/1.1 200 OK
# Mcp-Session-Id: <会话 id>
```

然后使用该会话 id：

```bash
SID=<id>
curl -s http://127.0.0.1:39281/mcp -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
curl -s http://127.0.0.1:39281/mcp -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openalex_search_works","arguments":{"query":"event sourcing","limit":3}}}'
```

终止会话：

```bash
curl -s -X DELETE http://127.0.0.1:39281/mcp -H "Mcp-Session-Id: $SID"
```

传输行为均按规范：不带会话 id 的 POST 得到 `400`，未知会话 id 得到 `404`，
通知（无 `id`，或只含通知的批处理）得到无主体的 `202 Accepted`，发送
`Accept: text/event-stream` 的客户端得到一小段 server-sent 流格式的响应而
不是 JSON 主体。批处理（`[{...},{...}]`）以 JSON 数组应答。

## 文件

| 文件 | 作用 |
|------|------|
| `main.lua` | Streamable HTTP 监听、路由、`lunet.http` 请求分帧 |
| `mcp.lua` | JSON-RPC 分发、工具 schema、`lunet.jsonic` 编解码 |
| `openalex.lua` | 基于 `lunet.httpc` 的 OpenAlex 客户端 |
| `dotenv.lua` | `.env` 加载器 |
