# mcp-openalex-sse — a tiny localhost MCP server

[中文文档](README-CN.md)

The canonical Lunet example: an [MCP](https://modelcontextprotocol.io/) server
speaking the SSE transport, exposing three tools backed by the free
[OpenAlex](https://openalex.org/) scholarly API:

| Tool | What it does | Cost (free $1/day budget) |
|------|--------------|---------------------------|
| `openalex_search_works` | Free-text search over ~250M papers | ~$0.001 per call |
| `openalex_get_work` | One work's metadata + abstract by OpenAlex ID / DOI / URL | free |
| `openalex_search_authors` | Author search with affiliation and citation counts | ~$0.001 per call |

No database, no filesystem state, loopback only. The only outbound traffic is
HTTPS to `api.openalex.org` via `lunet.httpc` (libcurl) — the process spends
its life idle in single-digit megabytes of RAM, which is the whole point of
running MCP servers on Lunet instead of a larger runtime.

## Setup

1. Get a free API key at <https://openalex.org/settings/api> (takes a minute)
   and put it in `.env` in the directory you run the server from:

   ```
   OPEN_ALEX_API_KEY=your_key_here
   ```

2. Build the runner and the HTTP client module (once):

   ```bash
   xmake build-release
   xmake build lunet-httpc
   ```

## Run

```bash
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" examples/mcp_openalex_sse/main.lua
# mcp-openalex listening on http://127.0.0.1:39281/sse
```

Point your MCP client at `http://127.0.0.1:39281/sse`. `MCP_PORT` in `.env`
(or the environment) changes the port.

## Try it with curl

Open the SSE stream in one terminal:

```bash
curl -N http://127.0.0.1:39281/sse
# event: endpoint
# data: /message?sessionId=<id>
```

Then in another, using the session id from the stream:

```bash
SID=<id>
curl -X POST "http://127.0.0.1:39281/message?sessionId=$SID" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
curl -X POST "http://127.0.0.1:39281/message?sessionId=$SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
curl -X POST "http://127.0.0.1:39281/message?sessionId=$SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openalex_search_works","arguments":{"query":"event sourcing","limit":3}}}'
```

Responses arrive on the SSE stream as `event: message` frames.

## Files

| File | Role |
|------|------|
| `main.lua` | HTTP/SSE listener, routing, request framing |
| `mcp.lua` | JSON-RPC dispatch, tool schemas |
| `sse.lua` | SSE session store and stream pump |
| `openalex.lua` | OpenAlex client on `lunet.httpc` |
| `json.lua` | Minimal pure-Lua JSON encode/decode |
| `dotenv.lua` | `.env` loader |
