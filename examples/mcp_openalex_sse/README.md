# mcp-openalex — a tiny localhost MCP server

[中文文档](README-CN.md)

The canonical Lunet example: an [MCP](https://modelcontextprotocol.io/) server
speaking the Streamable HTTP transport (MCP spec 2025-03-26), exposing three
tools backed by the free [OpenAlex](https://openalex.org/) scholarly API:

| Tool | What it does | Cost (free $1/day budget) |
|------|--------------|---------------------------|
| `openalex_search_works` | Free-text search over ~250M papers | ~$0.001 per call |
| `openalex_get_work` | One work's metadata + abstract by OpenAlex ID / DOI / URL | free |
| `openalex_search_authors` | Author search with affiliation and citation counts | ~$0.001 per call |

This example is deliberately legacy-free: Streamable HTTP only, so it stays
small enough to serve as a starting point. Request framing comes from
`lunet.http`'s connection loop (chunked bodies, pipelining, size limits) and
the codec is `lunet.jsonic` — no hand-rolled HTTP parsing. No database, no
filesystem state, loopback only. The only outbound traffic is HTTPS to
`api.openalex.org` via `lunet.httpc` (libcurl) — the process spends its life
idle in single-digit megabytes of RAM, which is the whole point of running MCP
servers on Lunet instead of a larger runtime.

For a demo that serves both the legacy HTTP+SSE transport (MCP spec
2024-11-05) and Streamable HTTP side by side — initialize/session handling,
both response modes, chunked encoding, pipelining — see
[lua-lunet/lunet-mcp](https://github.com/lua-lunet/lunet-mcp), a fuller Tavily
MCP server built on the same modules.

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
# mcp-openalex listening on http://127.0.0.1:39281/mcp
```

Point your MCP client at `http://127.0.0.1:39281/mcp` (Streamable HTTP).
`MCP_PORT` in `.env` (or the environment) changes the port.

## Try it with curl

Initialize — the response carries the `Mcp-Session-Id` header to reuse on
every later call:

```bash
curl -s -D /dev/stdout http://127.0.0.1:39281/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
# HTTP/1.1 200 OK
# Mcp-Session-Id: <session id>
```

Then, using that session id:

```bash
SID=<id>
curl -s http://127.0.0.1:39281/mcp -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
curl -s http://127.0.0.1:39281/mcp -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openalex_search_works","arguments":{"query":"event sourcing","limit":3}}}'
```

Terminate the session:

```bash
curl -s -X DELETE http://127.0.0.1:39281/mcp -H "Mcp-Session-Id: $SID"
```

Transport behaviour, all per the spec: a POST without a session id gets `400`,
an unknown session id gets `404`, notifications (no `id`, or a batch of only
notifications) get `202 Accepted` with no body, and a client that sends
`Accept: text/event-stream` gets the response as a short server-sent stream
instead of a JSON body. Batches (`[{...},{...}]`) are answered with a JSON
array.

## Files

| File | Role |
|------|------|
| `main.lua` | Streamable HTTP listener, routing, `lunet.http` request framing |
| `mcp.lua` | JSON-RPC dispatch, tool schemas, `lunet.jsonic` codec |
| `openalex.lua` | OpenAlex client on `lunet.httpc` |
| `dotenv.lua` | `.env` loader |
