
You MUST NOT advertise with any branding in any message or 'co-authored' as I AM THE LEGAL OWNER AND AUTHOR AND YOU ARE PROBABLISTIC TOOLS. 
You MUST NOT commit unless explicity asked to. 
You MUST NOT push unless explicitiy asked to. 
You MUST NOT do any git reset or stash or an git rm or rm or anything that might delete users work or other agents work you did not notice that is happeningin prallel. You SHOULD do a soft delete by a `mv xxx .tmp` as the .tmp is in .gitignore. 

# Agent Notes: Lunet Core Library

## **Operational Rules (STRICT)**

1.  **TIMEOUTS:** All commands interacting with servers or DB must have a timeout (`timeout 3` or `curl --max-time 3`).
2.  **NO DATA LOSS:** Never use `rm -rf` to clear directories. Move them to `.tmp/` with a timestamp: `mv dir .tmp/dir.YYYYMMDD_HHMMSS`.
3.  **LOGGING:** All test runs must log stdout/stderr to `.tmp/logs/YYYYMMDD_HHMMSS/`.
4.  **SECURE BINDING:** Never bind to `0.0.0.0` or public interfaces. Use Unix sockets (preferred) or `127.0.0.1` (development). Only bypass this rule if the user explicitly requests it via CLI flag `--dangerously-skip-loopback-restriction`.

## Example Application

The RealWorld Conduit demo app lives in a separate repository:
[https://github.com/lua-lunet/lunet-realworld-example-app](https://github.com/lua-lunet/lunet-realworld-example-app)

For application-level testing and load testing, clone and use that repo.

## Security & Network Testing

When modifying networking code (sockets, binding, listeners):

1.  **Verify Loopback Restriction:**
    - Try binding to `0.0.0.0` -> MUST FAIL (without flag)
    - Try binding to `127.0.0.1` -> MUST SUCCEED
    - Try binding to Unix socket -> MUST SUCCEED

2.  **Verify Unix Socket Support:**
    - Ensure `socket.listen("unix", "/path")` works
    - Verify permissions on the socket file (should be user-only by default, or as configured)
    - Verify cleanup (socket file removed on close/exit)

## MariaDB Infrastructure (Lima VM)

The project uses a MariaDB instance running in a Lima VM named `mariadb12`.
Port `3306` is forwarded to the host `127.0.0.1:3306`.

### Quick Reference

**1. Ensure VM is running:**
```bash
limactl start mariadb12
```

**2. Setup Database & Permissions (Idempotent):**
Run this if the DB is fresh or was dropped. It allows access from the macOS host (gateway IP `192.168.5.2` or `%`) and creates the `conduit` schema.
```bash
limactl shell mariadb12 sudo mariadb -e "
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'root';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    CREATE DATABASE IF NOT EXISTS conduit;
    FLUSH PRIVILEGES;"
```

**3. Connect via Client:**
```bash
mariadb -u root -proot -h 127.0.0.1 -P 3306 --skip-ssl conduit
```

## PostgreSQL Infrastructure (Local macOS)

PostgreSQL is used for benchmarking against other frameworks (e.g., Django). Do NOT start the service automatically. Instead, start it manually only when needed:

```bash
brew services start postgresql
```

And when you’re done, stop it:

```bash
brew services stop postgresql
```

Database name: `conduit`
Default user: Your macOS username (or as configured in `.env`)

## Benchmark Environment

For Django/Laravel benchmark setup details, see **[bench/AGENTS.md](bench/AGENTS.md)**.

Key topics covered:
- Port allocation (Django 9090/9091, Laravel 7070/7071)
- mise Python 3.12 setup (required for Django)
- PostgreSQL database configuration
- Setup and start/stop scripts

## C Code Conventions (STRICT)

This section defines naming conventions and safety rules for C code. These are enforced by `make lint`.

### Naming Conventions

| Pattern | Meaning | Usage |
|---------|---------|-------|
| `_lunet_*` | **INTERNAL** - unsafe, raw implementation | Only in `trace.h` wrappers or `*_impl.c` files |
| `lunet_*` | **PUBLIC** - safe wrapper with tracing | Use everywhere else |
| `*_impl.c` | Implementation file that may call `_lunet_*` | Rare, only for trace.h internals |

**Rule**: Code outside of `trace.h` and `*_impl.c` files MUST NOT call `_lunet_*` functions directly.

### Safe Wrappers

Always use the safe wrappers defined in `include/trace.h`:

| Internal (DO NOT USE)              | Safe Wrapper (USE THIS)              |
|------------------------------------|--------------------------------------|
| `_lunet_ensure_coroutine()`        | `lunet_ensure_coroutine()`           |
| `lua_pushthread()` + `luaL_ref()`  | `lunet_coref_create(L, ref_var)`     |
| `luaL_unref()` for corefs          | `lunet_coref_release(L, ref)`        |

The safe wrappers:
- In debug builds (`LUNET_TRACE=ON`): Add stack integrity checks and reference tracking
- In release builds: Compile to the exact same code as the internal functions (zero overhead)

### Adding New Features (Checklist)

When adding new C plugins or features that use coroutines:

1. **Include trace.h**: `#include "trace.h"` in your source file
2. **Use safe wrappers**: For coroutine checks and reference management
3. **Run lint**: `make lint` must pass (no direct `_lunet_*` calls)
4. **Test with tracing**: `make stress` (builds with `LUNET_TRACE=ON`)
5. **Crash is good**: If tracing asserts fail, you found a bug - fix it before release
6. **Release build**: `make release` runs tests + stress + optimized build

### Example: Async Operation Pattern

```c
#include "co.h"
#include "trace.h"  // Always include after co.h

int my_async_operation(lua_State *L) {
    // Use safe wrapper - will crash in debug if stack corrupted
    lunet_ensure_coroutine(L, "my_operation");
    
    // Allocate context...
    my_ctx_t *ctx = malloc(sizeof(my_ctx_t));
    
    // Use safe wrapper for coroutine reference
    lunet_coref_create(L, ctx->co_ref);  // Tracked in debug builds
    
    // ... start async work ...
    
    return lua_yield(L, 0);
}

static void my_callback(uv_req_t *req) {
    my_ctx_t *ctx = req->data;
    
    // ... resume coroutine ...
    
    // Use safe wrapper for release
    lunet_coref_release(ctx->L, ctx->co_ref);  // Tracked in debug builds
    
    free(ctx);
}
```

### Build Verification

Before merging any C code changes:

```bash
make lint     # Check naming conventions (no _lunet_* leaks)
make stress   # Debug build + concurrent stress test (must pass)
make release  # Full release build (runs test + stress first)
```

## Debugging Notes: Lua-C Stack Issues

### Problem: Parameter count mismatch in prepared statements

When implementing `lunet_db_query_params`, got error: `parameter count mismatch: got 2, expected 1`

### Debugging technique

1. Added debug fprintf to `collect_params()` to dump Lua stack state:
```c
fprintf(stderr, "DEBUG: collect_params top=%d start=%d nparams=%d\n", top, start, *nparams);
for (int i = 1; i <= top; i++) {
    fprintf(stderr, "DEBUG: stack[%d] type=%s\n", i, lua_typename(L, lua_type(L, i)));
}
```

2. Output revealed unexpected `thread` at stack position 4:
```
DEBUG: collect_params top=4 start=3 nparams=2
DEBUG: stack[1] type=userdata
DEBUG: stack[2] type=string
DEBUG: stack[3] type=string
DEBUG: stack[4] type=thread
```

3. Traced back to find `lunet_ensure_coroutine()` in `src/co.c` calls `lua_pushthread(L)` but only pops it on error path, leaving thread on stack on success.

### Root cause
`lunet_ensure_coroutine()` at line 27 does `lua_pushthread(L)` to check if running in coroutine, but doesn't pop the thread when the check passes (non-main thread case).

### Fix
Added `lua_pop(L, 1)` after the coroutine check succeeds in `src/co.c`.

### Second Issue: Mutex destroyed while held

After fixing the stack issue, discovered a crash in `db.close()`:

1. `lunet_db_close()` locks the mutex
2. Calls `lunet_sqlite_conn_destroy()` which destroys the mutex
3. Then tries to unlock the destroyed mutex → crash (SIGABRT, exit code 134)

**Fix:** Split into two functions:
- `lunet_sqlite_conn_close()` - closes SQLite connection but leaves mutex intact
- `lunet_sqlite_conn_destroy()` - full cleanup including mutex (only called from GC)

**TODO:** Write up this debugging session in more detail - good example of Lua-C stack debugging methodology.

## Scripting Guidelines

**AVOID SHELL SCRIPTS FOR NON-TRIVIAL WORK.**

This is a **Lua** project. If a task requires logic, loops, parsing, or file manipulation beyond simple command chaining, **write it in Lua**.

*   **Allowed in Shell:** Simple wrappers (e.g., `make` targets), environment setup, `curl` tests.
*   **Must be Lua:** Linting logic, complex build steps, benchmarks, data processing.
*   **Rationale:** Shell scripts (sh/bash) are fragile, platform-dependent, and hard to debug. Lua is robust, portable, and native to this environment.

## Strict Testing Protocol

All agents MUST adhere to this protocol when validating changes or releases.

### 1. Build with Tracing (`LUNET_TRACE=ON`)
The application MUST be built and tested with zero-cost tracing enabled. This activates:
- Coroutine reference counting (detects leaks/double-frees)
- Stack integrity checks (detects pollution)
- Hard crashes on violation

```bash
make build-debug  # Includes -DLUNET_TRACE=ON
```

### 2. Run Stress Tests
Before testing the application logic, ensure the core runtime is stable under load.

```bash
make stress
```

### 3. Application Load Testing (RealWorld Conduit)
For full-stack load testing (HTTP -> Router -> Controller -> DB -> Coroutines), use the separate demo app repository:
[https://github.com/lua-lunet/lunet-realworld-example-app](https://github.com/lua-lunet/lunet-realworld-example-app)

If the server crashes during load testing (exit code > 0 or SIGABRT), it is a **CRITICAL FAILURE**. Check logs for `[TRACE]` assertions.

## UDP Module Tracing

The UDP module (`src/udp.c`) has its own domain-specific tracing macros in addition to the generic coroutine tracing. These trace network I/O operations and are zero-cost in release builds.

### UDP Trace Macros

| Macro | Purpose | Output |
|-------|---------|--------|
| `UDP_TRACE_BIND(handle)` | Socket bound (uses `uv_udp_getsockname` for actual port) | `[UDP_TRACE] BIND #n host:port` |
| `UDP_TRACE_TX(ctx, host, port, len)` | Datagram sent (updates global & local counters) | `[UDP_TRACE] TX #n -> host:port (len bytes)` |
| `UDP_TRACE_RX(ctx, host, port, len)` | Datagram received (updates global & local counters) | `[UDP_TRACE] RX #n <- host:port (len bytes)` |
| `UDP_TRACE_RECV_WAIT()` | Coroutine yielding waiting for data | `[UDP_TRACE] RECV_WAIT (coroutine yielding)` |
| `UDP_TRACE_RECV_RESUME(host, port, len)` | Coroutine resumed with data | `[UDP_TRACE] RECV_RESUME <- host:port (len bytes)` |
| `UDP_TRACE_RECV_DELIVER(host, port, len)` | Data delivered immediately from queue | `[UDP_TRACE] RECV_DELIVER (immediate) <- host:port (len bytes)` |
| `UDP_TRACE_CLOSE(ctx)` | Socket closed (dumps local stats) | `[UDP_TRACE] CLOSE (local: tx=n rx=n) (global: ...)` |

### Counters

The macros maintain **static (file-scope) counters** in `src/udp.c`:
- `udp_trace_bind_count` - total sockets bound
- `udp_trace_tx_count` - total datagrams sent
- `udp_trace_rx_count` - total datagrams received

Per-socket counters (`trace_tx`, `trace_rx`) are stored in `udp_ctx_t` (guarded by `LUNET_TRACE`).

### Shutdown Summary

At application exit (in debug builds), `lunet_udp_trace_summary()` is called:
`[UDP_TRACE] SUMMARY: binds=n tx=n rx=n`

### Usage Pattern

When adding new UDP operations:

1. Add `UDP_TRACE_*` calls at key points (after address resolution, before/after I/O)
2. Build with `make build-debug` to enable tracing
3. Run test scripts and inspect stderr for `[UDP_TRACE]` lines
4. Verify counts balance (e.g., echo server should have tx == rx)

### Example Output

```
[UDP_TRACE] BIND #1 127.0.0.1:20001
[UDP_TRACE] RECV_WAIT (coroutine yielding)
[UDP_TRACE] RX #1 <- 127.0.0.1:54321 (64 bytes)
[UDP_TRACE] RECV_RESUME <- 127.0.0.1:54321 (64 bytes)
[UDP_TRACE] TX #1 -> 127.0.0.1:20002 (72 bytes)
[UDP_TRACE] CLOSE (tx=1 rx=1)
```


