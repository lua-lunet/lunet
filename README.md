# Lunet

A high-performance coroutine-based networking library for LuaJIT, built on top of libuv.

[中文文档](README-CN.md)

> This project is based on [xialeistudio/lunet](https://github.com/xialeistudio/lunet) by [夏磊 (Xia Lei)](https://github.com/xialeistudio). See also his excellent write-up: [Lunet: Design and Implementation of a High-Performance Coroutine Network Library](https://www.ddhigh.com/en/2025/07/12/lunet-high-performance-coroutine-network-library/).

## Philosophy: No Bloat, No Kitchen Sink

Lunet is **modular by design**. You install only what you need:

- **Core** (`lunet`): TCP/UDP sockets, filesystem, timers, signals
- **Database drivers** (separate packages):
  - `lunet-sqlite3` - SQLite3 driver
  - `lunet-mysql` - MySQL/MariaDB driver
  - `lunet-postgres` - PostgreSQL driver

Install one database driver, not all three. No unused dependencies. No security patches for libraries you never use.

```bash
# Install core
luarocks install lunet

# Install ONLY the database driver you need
luarocks install lunet-sqlite3   # OR
luarocks install lunet-mysql     # OR
luarocks install lunet-postgres
```

### Why use lunet database drivers?

You might think "I can just use LuaJIT FFI to call sqlite3/libpq/libmysqlclient directly" - and you can. But those calls are **blocking**. They will freeze your entire event loop while waiting for the database.

Lunet database drivers are **coroutine-safe**:
- Queries run on libuv's thread pool (`uv_work_t`)
- Connections are mutex-protected for safe concurrent access
- Your coroutine yields while waiting, other coroutines keep running

If you use raw FFI database bindings inside a lunet application, you lose all the async benefits.

## Build

```bash
# Default SQLite build
make build

# Build with tracing (debug mode)
make build-debug
```

## Example: MCP-SSE Server

[lunet-mcp-sse](https://github.com/lua-lunet/lunet-mcp-sse) is an MCP (Model Context Protocol) server with Tavily web search, demonstrating:

- **SSE transport** - Server-Sent Events for real-time streaming
- **JSON-RPC over HTTP** - Stateful session management
- **External API calls** - Tavily search integration via curl
- **Zero-cost tracing** - Debug logging with no production overhead

**Why lunet for MCP servers?**

MCP servers are often deployed as sidecar processes. Lunet's dependencies (libuv, LuaJIT) are mature, stable libraries with Debian LTS support - no npm/pip churn or constant security patches.

| Implementation | Image Size | Runtime Memory |
|----------------|------------|----------------|
| **lunet-mcp-sse** | **171 MB** | **7 MB** |
| tavily-mcp (Node.js) | 420 MB | 18 MB |
| tavily-mcp (Bun) | 382 MB | 14 MB |
| FastMCP (Python) | 367 MB | 28 MB |

```bash
# Quick start
curl -L -o lunet-mcp-sse.tar.gz \
  https://github.com/lua-lunet/lunet-mcp-sse/releases/download/nightly/lunet-mcp-sse-linux-arm64.tar.gz
tar -xzf lunet-mcp-sse.tar.gz
echo "TAVILY_API_KEY=your_key" > .env
./run.sh
```

## How-To Examples

First build the runner:

```bash
make build
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)
```

| # | Example | What it shows | Requires | Run |
|---:|---------|---------------|----------|-----|
| 01 | [`examples/01_http_json.lua`](examples/01_http_json.lua) | Minimal HTTP server returning JSON | core (`lunet`, `lunet.socket`) | `"$LUNET_BIN" examples/01_http_json.lua` |
| 02 | [`examples/02_http_routing.lua`](examples/02_http_routing.lua) | Tiny router with `:params` in paths | core (`lunet`, `lunet.socket`) | `"$LUNET_BIN" examples/02_http_routing.lua` |
| 03 | [`examples/03_db_sqlite3.lua`](examples/03_db_sqlite3.lua) | SQLite3 CRUD + `query_params` / `exec_params` | `xmake build lunet-sqlite3` | `"$LUNET_BIN" examples/03_db_sqlite3.lua` |
| 04 | [`examples/04_db_mysql.lua`](examples/04_db_mysql.lua) | MySQL CRUD + prepared statements (`?`) | `xmake build lunet-mysql` + MySQL server | `"$LUNET_BIN" examples/04_db_mysql.lua` |
| 05 | [`examples/05_db_postgres.lua`](examples/05_db_postgres.lua) | Postgres CRUD + prepared statements (`$1`) | `xmake build lunet-postgres` + Postgres server | `"$LUNET_BIN" examples/05_db_postgres.lua` |

See also [lunet-realworld-example-app](https://github.com/lua-lunet/lunet-realworld-example-app) for a complete RealWorld "Conduit" API implementation.

## Core Modules

All networking MUST be called within a coroutine spawned via `lunet.spawn`.

### TCP / Unix Sockets (`lunet.socket`)

```lua
local socket = require("lunet.socket")

-- Server
local listener = socket.listen("tcp", "127.0.0.1", 8080)
local client = socket.accept(listener)

-- Client
local conn = socket.connect("127.0.0.1", 8080)

-- I/O
local data = socket.read(conn)
socket.write(conn, "hello")
socket.close(conn)
```

### UDP (`lunet.udp`)

```lua
local udp = require("lunet.udp")

-- Bind
local h = udp.bind("127.0.0.1", 20001)

-- I/O
udp.send(h, "127.0.0.1", 20002, "payload")
local data, host, port = udp.recv(h)

udp.close(h)
```

## Database Drivers

Database drivers are **separate packages**. Install only what you need:

```bash
luarocks install lunet-sqlite3   # SQLite3
luarocks install lunet-mysql     # MySQL/MariaDB
luarocks install lunet-postgres  # PostgreSQL
```

### SQLite3 (`lunet.sqlite3`)

```lua
local db = require("lunet.sqlite3")

-- Open database (file path or ":memory:")
local conn = db.open("myapp.db")

-- Execute (INSERT/UPDATE/DELETE) - returns affected rows
local rows = db.exec(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

-- Query (SELECT) - returns array of row tables
local users = db.query(conn, "SELECT * FROM users WHERE active = 1")
for _, user in ipairs(users) do
    print(user.id, user.name)
end

-- Parameterized queries (safe from SQL injection)
local results = db.query(conn, "SELECT * FROM users WHERE name = ?", "alice")
db.exec(conn, "INSERT INTO users (name) VALUES (?)", "bob")

-- Close connection
db.close(conn)
```

### MySQL/MariaDB (`lunet.mysql`)

```lua
local db = require("lunet.mysql")

-- Open connection
local conn = db.open({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "secret",
    database = "myapp"
})

-- Same API as SQLite3
local users = db.query(conn, "SELECT * FROM users")
db.exec(conn, "INSERT INTO users (name) VALUES (?)", "alice")

db.close(conn)
```

### PostgreSQL (`lunet.postgres`)

```lua
local db = require("lunet.postgres")

-- Open connection
local conn = db.open({
    host = "127.0.0.1",
    port = 5432,
    user = "postgres",
    password = "secret",
    database = "myapp"
})

-- Same API as SQLite3
local users = db.query(conn, "SELECT * FROM users")
db.exec(conn, "INSERT INTO users (name) VALUES ($1)", "alice")  -- PostgreSQL uses $1, $2, etc.

db.close(conn)
```

### Database API Summary

| Function | Description | Returns |
|----------|-------------|---------|
| `db.open(path_or_config)` | Open connection | connection handle |
| `db.close(conn)` | Close connection | - |
| `db.query(conn, sql, ...)` | Execute SELECT (with optional parameters) | array of row tables |
| `db.exec(conn, sql, ...)` | Execute INSERT/UPDATE/DELETE (with optional parameters) | affected row count |
| `db.query_params(conn, sql, ...)` | Alias for `db.query` (legacy) | array of row tables |
| `db.exec_params(conn, sql, ...)` | Alias for `db.exec` (legacy) | affected row count |
| `db.escape(conn, str)` | Escape string for SQL (rarely needed) | escaped string |

**Note**: All three drivers now use native prepared statements internally. Parameters are automatically bound using driver-native functions (`sqlite3_bind_*`, `mysql_stmt_bind_param`, `PQexecParams`), eliminating SQL injection risks.

## Safety: Zero-Cost Tracing

Build with `make build-debug` to enable coroutine reference tracking and stack integrity checks. The runtime will assert and crash on leaks or stack pollution.

## Testing

```bash
make test    # Unit tests
make stress  # Concurrent load test with tracing
```

## License

MIT
