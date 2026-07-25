# mcp-openalex-sse —— 微型 localhost MCP 服务器

[English Documentation](README.md)

Lunet 的规范示例：一个使用 SSE 传输的 [MCP](https://modelcontextprotocol.io/)
服务器，提供三个由免费 [OpenAlex](https://openalex.org/) 学术 API 支撑的工具：

| 工具 | 功能 | 费用（每日 $1 免费额度） |
|------|------|--------------------------|
| `openalex_search_works` | 在约 2.5 亿篇论文中做全文检索 | 每次约 $0.001 |
| `openalex_get_work` | 按 OpenAlex ID / DOI / URL 获取单篇元数据与摘要 | 免费 |
| `openalex_search_authors` | 按姓名检索作者，含机构与引用数 | 每次约 $0.001 |

无数据库、无文件状态、仅回环。唯一的出站流量是经 `lunet.httpc`（libcurl）
发往 `api.openalex.org` 的 HTTPS —— 进程空闲时只占个位数 MB 内存，这正是
用 Lunet 而不是更大运行时来跑 MCP 服务器的意义。

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
# mcp-openalex listening on http://127.0.0.1:39281/sse
```

把 MCP 客户端指向 `http://127.0.0.1:39281/sse`。`.env`（或环境变量）中的
`MCP_PORT` 可修改端口。

## 用 curl 试一试

先在一个终端打开 SSE 流：

```bash
curl -N http://127.0.0.1:39281/sse
# event: endpoint
# data: /message?sessionId=<id>
```

然后在另一个终端中使用流里给出的 session id：

```bash
SID=<id>
curl -X POST "http://127.0.0.1:39281/message?sessionId=$SID" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
curl -X POST "http://127.0.0.1:39281/message?sessionId=$SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
curl -X POST "http://127.0.0.1:39281/message?sessionId=$SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openalex_search_works","arguments":{"query":"event sourcing","limit":3}}}'
```

响应以 `event: message` 帧的形式到达 SSE 流。

## 文件

| 文件 | 作用 |
|------|------|
| `main.lua` | HTTP/SSE 监听、路由、请求分帧 |
| `mcp.lua` | JSON-RPC 分发、工具 schema |
| `sse.lua` | SSE 会话存储与流泵 |
| `openalex.lua` | 基于 `lunet.httpc` 的 OpenAlex 客户端 |
| `json.lua` | 极简纯 Lua JSON 编解码 |
| `dotenv.lua` | `.env` 加载器 |
