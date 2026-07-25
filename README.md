# Lunet

A high-performance coroutine-based networking library for LuaJIT, built on top of libuv.

[中文文档](README-CN.md)

[![EasyMem](https://img.shields.io/badge/EasyMem-easy__memory-27272d?style=flat&logo=github&logoColor=white)](https://github.com/EasyMem/easy_memory)

> This project is based on [xialeistudio/lunet](https://github.com/xialeistudio/lunet) by [夏磊 (Xia Lei)](https://github.com/xialeistudio). See also his excellent write-up: [Lunet: Design and Implementation of a High-Performance Coroutine Network Library](https://www.ddhigh.com/en/2025/07/12/lunet-high-performance-coroutine-network-library/).

Lunet began as a way to write **tiny localhost MCP servers** — Model Context Protocol tools that sit next to an LLM client on loopback, idle in single-digit megabytes of RAM, and start instantly. That is still the front-page use case. Long-form motivation: **[The Talos, Ethos and 無為 of Lunet](docs/PHILOSOPHY.md)**.

## Three ways to use Lunet

| Path | Who it is for | What you need | Start here |
|------|---------------|---------------|------------|
| **Run Lua** | You write Lua apps; no C toolchain | A release archive for your OS | [Releases](https://github.com/lua-lunet/lunet/releases) |
| **Package an appliance** | You ship one self-contained executable — your `main()` + Lunet + your app | The release SDK + a C compiler | [docs/EMBEDDING.md](docs/EMBEDDING.md) |
| **Hack the core** | You develop Lunet itself, or want a minimal feature build | xmake + system dev libraries | [docs/XMAKE_INTEGRATION.md](docs/XMAKE_INTEGRATION.md) |

## Security posture: loopback by default

Lunet refuses to bind listeners to anything other than `127.0.0.1`, `::1`, or a Unix socket — **no remote security holes by default**. To expose a service, put a battle-hardened sidecar in front (nginx, OpenResty, Caddy, Envoy — the admin picks) so protocol-smashing attacks die at the proxy, not in your Lua coroutine. On a private network whose only ingress is a hardened cloud proxy that scrubs bad traffic and absorbs DDoS, binding all interfaces can be safe — but Lunet makes you say that out loud with the explicit `--dangerously-skip-loopback-restriction` flag. Details: [docs/SECURITY_ARCHITECTURE.md](docs/SECURITY_ARCHITECTURE.md).

## Philosophy: No Bloat, No Kitchen Sink

Lunet is **modular by design**. You build only what you need:

- **Core** (`lunet`): TCP/UDP sockets, filesystem, timers, signals
- **Database drivers** (optional xmake targets):
  - `lunet-sqlite3` - SQLite3 driver
  - `lunet-mysql` - MySQL/MariaDB driver
  - `lunet-postgres` - PostgreSQL driver
- **Outbound HTTPS client** (optional xmake target):
  - `lunet-httpc` - HTTPS client via libcurl (`require("lunet.httpc")`)
- **Shared dictionary** (optional Rust extension, Linux/macOS):
  - `lunet.lnt_shared` - lunet-style shared dict via Rust FFI (`xmake build-lnt-shared`)
- **JSON** (optional Rust extension, Linux/macOS):
  - `lunet.jsonic` - dkjson-style encode/decode; decode via Rust FFI wrapping [jsonic](https://github.com/g1mv/jsonic) (`xmake build-jsonic`)

Build one database driver, not all three. No unused dependencies. No security patches for libraries you never use.

Getting started (build flow, profiles, and integration details):
- **[docs/PHILOSOPHY.md](docs/PHILOSOPHY.md)** (the long-form why)
- **[docs/XMAKE_INTEGRATION.md](docs/XMAKE_INTEGRATION.md)**
- **[docs/HTTPC.md](docs/HTTPC.md)** (optional outbound HTTPS client)

### Why use lunet database drivers?

You might think "I can just use LuaJIT FFI to call sqlite3/libpq/libmysqlclient directly" - and you can. But those calls are **blocking**. They will freeze your entire event loop while waiting for the database.

Lunet database drivers are **coroutine-safe**:
- Queries run on libuv's thread pool (`uv_work_t`)
- Connections are mutex-protected for safe concurrent access
- Your coroutine yields while waiting, other coroutines keep running

If you use raw FFI database bindings inside a lunet application, you lose all the async benefits.

## Build

```bash
# Default SQLite build (also builds the lunet-static SDK archive and sdk-api-test)
xmake build-release

# Build with tracing (debug mode)
xmake build-debug
```

LuaJIT, libuv, and zlib are required dependencies; each driver adds only its own client library. Release profiles strip EasyMem by default. Use debug/ASan profiles for EasyMem diagnostics.

## Example: MCP-SSE Servers

For a minimal in-repo starting point see [`examples/mcp_openalex_sse/`](examples/mcp_openalex_sse/) — an SSE-transport MCP server that calls the [OpenAlex](https://openalex.org/) scholarly API via `lunet.httpc`, with no database and no filesystem state.

[lunet-mcp-sse](https://github.com/lua-lunet/lunet-mcp-sse) is a fuller MCP (Model Context Protocol) server with Tavily web search, demonstrating:

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
xmake build-release
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)
```

| # | Example | What it shows | Requires | Run |
|---:|---------|---------------|----------|-----|
| 01 | [`examples/01_http_json.lua`](examples/01_http_json.lua) | Minimal HTTP server returning JSON | core (`lunet`, `lunet.socket`) | `"$LUNET_BIN" examples/01_http_json.lua` |
| 02 | [`examples/02_http_routing.lua`](examples/02_http_routing.lua) | Tiny router with `:params` in paths | core (`lunet`, `lunet.socket`) | `"$LUNET_BIN" examples/02_http_routing.lua` |
| 03 | [`examples/03_db_sqlite3.lua`](examples/03_db_sqlite3.lua) | SQLite3 CRUD + `query_params` / `exec_params` | `xmake build lunet-sqlite3` | `"$LUNET_BIN" examples/03_db_sqlite3.lua` |
| 04 | [`examples/04_db_mysql.lua`](examples/04_db_mysql.lua) | MySQL CRUD + prepared statements (`?`) | `xmake build lunet-mysql` + MySQL server | `"$LUNET_BIN" examples/04_db_mysql.lua` |
| 05 | [`examples/05_db_postgres.lua`](examples/05_db_postgres.lua) | Postgres CRUD + prepared statements (`$1`) | `xmake build lunet-postgres` + Postgres server | `"$LUNET_BIN" examples/05_db_postgres.lua` |
| 08 | [`examples/08_lnt_shared.lua`](examples/08_lnt_shared.lua) | lunet-style shared dictionary via Rust FFI | `xmake build-lnt-shared` | `"$LUNET_BIN" examples/08_lnt_shared.lua` |
| 09 | [`examples/09_jsonic_demo.lua`](examples/09_jsonic_demo.lua) | dkjson-style JSON encode/decode via Rust FFI | `xmake build-jsonic` | `"$LUNET_BIN" examples/09_jsonic_demo.lua` |
| 10 | [`examples/mcp_openalex_sse/`](examples/mcp_openalex_sse/) | **Canonical tiny MCP server**: SSE transport + OpenAlex API via `lunet.httpc`, no DB, loopback only | `xmake build lunet-httpc` + `OPEN_ALEX_API_KEY` in `.env` | `"$LUNET_BIN" examples/mcp_openalex_sse/main.lua` |

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

Database drivers are **optional build targets**. Build only what you need:

```bash
xmake build lunet-sqlite3   # SQLite3
xmake build lunet-mysql     # MySQL/MariaDB
xmake build lunet-postgres  # PostgreSQL
```

### SQLite3 (`lunet.sqlite3`)

```lua
local db = require("lunet.sqlite3")

-- Open database (file path or ":memory:")
local conn = db.open("myapp.db")

-- Execute (INSERT/UPDATE/DELETE) - returns metadata
local result = db.exec(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
print(result.affected_rows)

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
| `db.exec(conn, sql, ...)` | Execute INSERT/UPDATE/DELETE (with optional parameters) | result table (`affected_rows`, `last_insert_id`) |
| `db.query_params(conn, sql, ...)` | Same behavior as `db.query` | array of row tables |
| `db.exec_params(conn, sql, ...)` | Same behavior as `db.exec` | result table (`affected_rows`, `last_insert_id`) |

**Note**: All three drivers use native prepared statements internally. Parameters are automatically bound using driver-native functions (`sqlite3_bind_*`, `mysql_stmt_bind_param`, `PQexecParams`), eliminating SQL injection risks. There is deliberately no `db.escape`: hand-escaping is never needed, and never as safe as binding.

### Transactions

Pass a connection handle you hold, and issue the transaction control statements
like any other statement:

```lua
db.exec(conn, "BEGIN")
local ok, err = pcall(function()
    db.exec(conn, "DELETE FROM nodes WHERE path = $1", dst)
    db.exec(conn, "UPDATE nodes SET path = $1 WHERE path = $2", dst, src)
end)
db.exec(conn, ok and "COMMIT" or "ROLLBACK")
```

Two properties to be aware of:

- **A statement with bound parameters must be a single command.** That is
  libpq/MySQL extended-protocol behaviour, not a Lunet restriction. Statements
  with *no* parameters may contain several commands separated by `;`, but only
  the last command's rows and `affected_rows` are returned.
- **The transaction lives on the connection handle, not on the coroutine.** All
  statements in a transaction must use the same `conn`. If your application
  pools connections, pin one handle for the whole transaction — a pool that
  leases a connection per call will scatter `BEGIN` and `COMMIT` across
  different sessions. Do not let another coroutine use that handle until you
  have committed.

### Shared Dictionary (`lunet.lnt_shared`) — Linux / macOS

A lunet-style shared dictionary backed by a Rust FFI library. It is a pure
opt-in extension.

**Build** (requires Rust 1.85+ / 2024 edition):
```bash
xmake build-lnt-shared   # runs: cargo build --release in ext/lnt_shared/
```

**Usage**:
```lua
-- Load the wrapper (after building the Rust library)
local script_dir = debug.getinfo(1,"S").source:match("^@(.+)/[^/]+$") or "."
local lnt = loadfile(script_dir .. "/../ext/lnt_shared/lnt_shared.lua")()

local cache = lnt.store("my_cache", 1024 * 1024)  -- 1 MiB

-- Strings, numbers, and booleans
cache:set("key", "value")
cache:set("hits", 0)
cache:set("active", true)

-- Atomic increment (creates key with init=0 if absent)
cache:incr("hits", 1, 0)

-- TTL (seconds, fractional OK)
cache:set("session", "token123", 30)  -- expires in 30 s

-- Standard dict operations
cache:add("lock", "worker-1")         -- only if absent
cache:replace("lock", "worker-2")     -- only if present
cache:delete("lock")

-- Bulk
cache:flush_all()
local evicted = cache:flush_expired()

-- Stats
print(cache:capacity(), cache:free_space())

-- Handles are GC-managed (ffi.gc finalizer); close eagerly if desired.
-- The shared region itself outlives any single handle.
cache:close()
```

**Architecture**: one `mmap(MAP_ANONYMOUS|MAP_SHARED)` region per named
dictionary; all state lives in the region (no heap for persistent data);
FNV-1a open-address hash table; bump allocator; single spinlock.  Multiple
handles opened with the same name share the same region within a process.

### JSON (`lunet.jsonic`) — Linux / macOS

A dkjson-compatible `encode`/`decode`/`null` API. Decoding is backed by a
Rust FFI wrapper around [jsonic](https://github.com/g1mv/jsonic) (MIT /
Apache-2.0, zero runtime dependencies) — see `ext/jsonic/NOTICE.md` for full
attribution. `jsonic` itself only parses; `encode()` is plain, dependency-free
Lua.

**Build** (requires Rust 1.85+ / 2024 edition):
```bash
xmake build-jsonic   # runs: cargo build --release in ext/jsonic/
```

**Usage**:
```lua
local script_dir = debug.getinfo(1,"S").source:match("^@(.+)/[^/]+$") or "."
local json = loadfile(script_dir .. "/../ext/jsonic/jsonic.lua")()

local value, pos, err = json.decode('{"a":1,"b":[true,null]}')
-- value = { a = 1, b = { true, json.null } }

local str = json.encode({ a = 1, b = { true, json.null } })
-- str = '{"a":1,"b":[true,null]}'

json.encode({ a = 1 }, { indent = true, keyorder = { "a" } })
```

**Maelstrom rig**: [`ext/jsonic/maelstrom/`](ext/jsonic/maelstrom/README.md)
runs the jsonic demo as a Maelstrom (Jepsen) node — Docker on arm64, no
volume mounts, loopback-only — via `make -C ext/jsonic/maelstrom test`.

## Safety: Zero-Cost Tracing

Build with `xmake build-debug` to enable coroutine reference tracking and stack integrity checks. The runtime will assert and crash on leaks or stack pollution.

## Debugging

Lunet has a layered debugging strategy for runtime crashes. Use them in order — each level is more expensive but gives more detail.

### Quick Reference

| Level | Tool | What it catches | Build command |
|-------|------|----------------|---------------|
| 1 | Domain tracing | Logic errors, sequence of operations | `xmake f --lunet_trace=y --lunet_verbose_trace=y` |
| 2 | Memory tracing + EasyMem | UAF, double-free, leaks, allocator integrity | `xmake f --lunet_trace=y` (EasyMem auto-enabled) |
| 3 | Address Sanitizer + EasyMem | Compiler-level memory errors plus allocator diagnostics | `xmake f -m debug --asan=y` |
| 4 | lldb / core dumps | Register-level inspection, full backtraces | `lldb -- ./build/.../lunet-run app.lua` |

### Domain Tracing (Level 1)

Every module (socket, timer, fs, udp, signal) has `*_TRACE_*` macros that log to stderr. Build with verbose tracing enabled:

```bash
xmake f -c -y --lunet_trace=y --lunet_verbose_trace=y
xmake build lunet-bin
./build/.../lunet-run app.lua 2> trace.log
```

When the trace log cuts off abruptly, the crash is between the last printed line and the next operation. Use this to narrow down which callback and which line.

### Address Sanitizer (Level 3)

ASan is the most effective tool for memory corruption bugs. It instruments every memory access and catches use-after-free, buffer overflows, and stack corruption with exact source locations:

```bash
xmake f -c -y -m debug --lunet_trace=y --asan=y
xmake build lunet-bin
./build/.../lunet-run app.lua 2> asan.log
```

With `--asan=y`, Lunet now also enables the EasyMem backend with diagnostic mode (`LUNET_EASY_MEMORY_DIAGNOSTICS`) so allocator-level integrity checks and profiling output run alongside ASan.

ASan output goes to stderr. The process exits with `Abort trap: 6` instead of `Segmentation fault: 11`. Look for `ERROR: AddressSanitizer:` in the log.

#### Full LuaJIT + Lunet ASan (Debian Trixie source)

To instrument both Lunet and LuaJIT (not just Lunet C code), build the OpenResty LuaJIT source package used by Debian Trixie and link Lunet against it:

```bash
xmake luajit-asan
xmake build-debug-asan-luajit
xmake repro-50-asan-luajit
```

These helper targets now inherit EasyMem automatically because they configure `--asan=y --lunet_trace=y`.

This uses Debian source package `luajit_2.1.0+openresty20250117-2` and installs a local ASan LuaJIT into `.tmp/luajit-asan/install/2.1.0+openresty20250117/`.

The version pins are configured in `xmake.lua` options (`luajit_snapshot`, `luajit_debian_version`).
Override them with:

```bash
xmake f --luajit_snapshot=2.1.0+openresty20250117 --luajit_debian_version=2.1.0+openresty20250117-2 -y
```

#### macOS / Xcode setup for symbolized ASan output

On macOS, ensure the Xcode toolchain is active so ASan reports include file/line symbols:

```bash
xcode-select -p
xcrun --find clang
xcrun --find llvm-symbolizer
export ASAN_SYMBOLIZER_PATH="$(xcrun --find llvm-symbolizer)"
export ASAN_OPTIONS="abort_on_error=1,halt_on_error=1,fast_unwind_on_malloc=0,detect_leaks=0"
```

If `xmake luajit-asan` fails with `missing: export MACOSX_DEPLOYMENT_TARGET=XX.YY`, set:

```bash
export MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion | awk -F. '{print $1 "." $2}')"
```

#### ASan-first crash hunting (force fast bailout)

Do not rely only on edge tracing to infer the fault location. First try to make LuaJIT/Lunet crash immediately under ASan:

```bash
xmake build-debug-asan-luajit
xmake repro-50-asan-luajit
```

If the bug is timing-sensitive, run more iterations:

```bash
ITERATIONS=100 REQUESTS=100 CONCURRENCY=8 WORKERS=8 xmake repro-50-asan-luajit
```

To reduce JIT-side nondeterminism while isolating yield/resume bookkeeping bugs, disable JIT in the repro Lua entrypoint:

```lua
local ok, jit = pcall(require, "jit")
if ok and jit then jit.off() end
```

This keeps execution in interpreter mode and often makes coroutine/state-machine faults reproducible faster under ASan.

### Coroutine Resume Tracing

The `lunet_co_resume()` wrapper logs `[CO_TRACE] RESUME` / `[CO_TRACE] RESUMED` around every `lua_resume` call (when verbose trace is enabled). This proves whether a crash is inside the Lua VM or in the C setup code around it.

### Wait/Resume Bookkeeping Assertions (Debug-only)

With `LUNET_TRACE=ON`, socket and UDP paths now track wait/resume sequence numbers and in-flight state for:

- socket: `accept`, `read`, `write`
- udp: `recv`

Any illegal transition (duplicate wait, resume without wait, or resume sequence ahead of wait sequence) prints `BK_FAIL` and triggers an assertion immediately. This is designed to catch coroutine pump/state-machine bookkeeping bugs at first violation instead of requiring edge-trace inference.

### Zero-Cost Release Guarantee

All bookkeeping, trace counters, canaries, and assertions are compiled only under `LUNET_TRACE`. Release builds (`--lunet_trace=n`) compile these checks out completely, so there is no runtime tax from debug instrumentation.

### Common Crash Signature: `lua_rawgeti` in Callbacks

If a crash happens inside `lua_rawgeti` from a libuv callback, it often means the `lua_State*` used for registry operations is invalid (dangling or corrupted). Avoid storing ephemeral coroutine `lua_State*` pointers in long-lived handles; use the owning main state for registry access and use corefs to track the waiting coroutine.

### Memory Tracing

When `LUNET_TRACE` is enabled, all allocations through `lunet_alloc()` / `lunet_free()` are tracked with canary headers and poison-on-free. EasyMem is also enabled automatically in trace builds, providing allocator-level integrity checks and memory usage visualization. At shutdown, `lunet_mem_assert_balanced()` checks for leaks. Use `lunet_alloc` / `lunet_free` instead of raw `malloc` / `free` in all lunet C code.

## Developer Workflow

xmake is the canonical build system. There is no Makefile. All tasks are defined in `xmake.lua`.

| Task | Description |
|------|-------------|
| `xmake lint` | C safety lint checks |
| `xmake check` | luacheck static analysis |
| `xmake test` | Unit tests (busted) |
| `xmake build-release` | Optimized release build |
| `xmake build-debug` | Debug build with tracing |
| `xmake examples-compile` | Examples compile/syntax check |
| `xmake sqlite3-smoke` | SQLite3 example smoke test |
| `xmake build-lnt-shared` | Build the lnt_shared Rust extension |
| `xmake lnt-shared-smoke` | Build lnt_shared then run its smoke test |
| `xmake build-jsonic` | Build the jsonic Rust extension |
| `xmake jsonic-smoke` | Build jsonic then run its smoke test |
| `xmake stress` | Concurrent load test with tracing |
| `xmake ci` | Local CI parity (lint + build + examples + sqlite3 smoke) |
| `xmake preflight-easy-memory` | EasyMem + ASan preflight gate |
| `xmake release` | Full release gate (lint + test + stress + preflight + build) |

For the complete task catalog and recommended workflows, see **[docs/WORKFLOW.md](docs/WORKFLOW.md)**.

### Quick Testing

```bash
xmake test    # Unit tests
xmake stress  # Concurrent load test with tracing
xmake ci      # Full local CI parity check
```

## Downstream Integration

- **[Integration guide](docs/XMAKE_INTEGRATION.md)** — Build Lunet and integrate it into your project (beginner-friendly)
- **[Badge guide](docs/BADGES.md)** — Add badges (build status, Lunet version) to your project README
- **[EasyMem report](docs/EASY_MEMORY_REPORT.md)** — Profiling findings and next-step memory recommendations

## License

MIT
