# The lunet demo fleet

Lunet is about *not* needing a kitchen sink: a small runtime you assemble from
exactly the pieces a service needs, and nothing else. Yet the demos collected
here demonstrate that it can do a full range of things — raw HTTP, four SQL
drivers, encrypted datagrams, MCP servers, embedding in a C host, and a
complete RealWorld application. Less by design, not less capable.

## The demo applications

| # | Application | What it is | Where |
|---|-------------|------------|-------|
| 1 | twelve-dollar-server-challenge | A realistic Feed API on SQLite for a resource-constrained host | [lua-lunet/twelve-dollar-server-challenge](https://github.com/lua-lunet/twelve-dollar-server-challenge) |
| 2 | realworld-lua | The RealWorld "Conduit" application | [lua-lunet/realworld-lua](https://github.com/lua-lunet/realworld-lua) |
| 3 | lunet-mcp-sse | A production MCP server over SSE, shipped as a Docker image | [lua-lunet/lunet-mcp-sse](https://github.com/lua-lunet/lunet-mcp-sse) |
| 4 | lunet-backproxy | An outbound-only reverse proxy for DMZ topologies | [lua-lunet/lunet-backproxy](https://github.com/lua-lunet/lunet-backproxy) |
| 5 | examples/mcp_openalex_sse | A complete MCP-over-SSE demo, in this repository | [examples/mcp_openalex_sse](mcp_openalex_sse/) |

### 1. twelve-dollar-server-challenge

A Feed API — read a feed, post a message, like a post — backed by in-process
SQLite, written for a host constrained to 1 vCPU and 2 GB of RAM: that is the
machine the challenge rents for twelve dollars a year. It is the case in point
for this folder: the whole submission is application logic (`server.lua` plus
`app/` routes, JWT and SQLite access), and efficiency and size is where lunet
should shine. In our own unofficial testing the lunet runtime serving the
submission's `server.lua` held a resident set of **3.7 MB after boot** and
**4.1 MB settled after 25 sequential loopback requests**. That observation is
unofficial, period — the submission is not yet merged into the challenge, and
nothing here claims any score on any machine.

### 2. realworld-lua

The RealWorld "Conduit" application — registration, authentication, articles,
comments and follows on PostgreSQL — as an ordinary, typical webapp. The
resource story can go unnoticed in a RealWorld demo, so its
[README carries a measured comparison table](https://github.com/lua-lunet/realworld-lua#resource-footprint)
against the Node.js and Python/Django implementations of the same spec; see
that table rather than trust a summary of it.

### 3. lunet-mcp-sse

A production MCP server speaking the SSE transport, published as a Docker
image for use behind an AI assistant. Its README is where the sizes live, and
the sizes are about overhead: a 171 MB image and ~7 MB of resident runtime
against the 367–420 MB images and 14–28 MB runtimes of the Node.js, Bun and
Python MCP implementations it lists. The container images exist so the server
can be dropped into an existing deployment unchanged.

### 4. lunet-backproxy

A reverse proxy where the protected zone has no inbound path at all: internal
workers connect *out* to a broker in the DMZ — sitting behind nginx/OpenResty —
and HTTP requests are tunnelled over those outbound connections. It is
uniquely secure in that respect, following the QMail school of one process,
one focused job across a trust boundary. As a demo it proves versatility:
the same runtime that serves HTTP handlers is comfortable carrying a
security-topology role.

### 5. examples/mcp_openalex_sse

The local, in-repo, complete demo: an MCP server over SSE with three tools
backed by the free OpenAlex scholarly API, loopback only, no database. It is
the clone-and-run one — clone this repository, build the runtime, put an
OpenAlex API key in a `.env` file, and run
`examples/mcp_openalex_sse/main.lua` with the built `lunet-run`; its
[README](mcp_openalex_sse/README.md) has the exact commands.

## The in-repo demo files

The `examples/` directory doubles as the in-tree index. Each entry is a small,
self-contained demonstration of one surface of the runtime:

| Entry | What it demonstrates |
|-------|----------------------|
| `01_http_json.lua` | Raw HTTP/1.1 with hand-rolled JSON escaping on `lunet.socket` — a JSON API with no libraries |
| `02_http_routing.lua` | A hand-rolled routing table with `:param` patterns over raw sockets |
| `03_db_sqlite3.lua` | The bundled SQLite3 driver: schema creation and basic CRUD |
| `04_db_mysql.lua` | The MySQL driver against a local server (env-configured) |
| `05_db_postgres.lua` | The PostgreSQL driver on libpq |
| `06_paxe_encryption.lua` | PAXE datagram encryption: seal/open, per-socket protection |
| `07_paxe_stress.lua` | PAXE stress test: payload sizes across the 64-byte seam, deliberate failure injection |
| `08_http.lua` | The `lunet.http` + `http_router` + `lnt_shared` wiring in one runnable file |
| `09_jsonic_demo.lua` | The jsonic extension: Rust-backed JSON decode behind a dkjson-style API |
| `10_db_prepared.lua` | SQLite prepared statements |
| `mcp_openalex_sse/` | The complete MCP-over-SSE demo (see above) |
| `sdk_embed/` | Embedding the lunet runtime in a C host program with embedded scripts |
