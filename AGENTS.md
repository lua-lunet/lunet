
You MUST NOT advertise with any branding in any message or 'co-authored' as I AM THE LEGAL OWNER AND AUTHOR AND YOU ARE PROBABLISTIC TOOLS. 
You MUST NOT commit unless explicity asked to. 
You MUST NOT push unless explicitiy asked to. 
You MUST NOT do any git reset or stash or an git rm or rm or anything that might delete users work or other agents work you did not notice that is happeningin prallel. You SHOULD do a soft delete by a `mv xxx .tmp` as the .tmp is in .gitignore. 

# Agent Notes: RealWorld Conduit Backend

## **Operational Rules (STRICT)**

1.  **NO RAW CURL:** Do not run `curl` directly against the server. Use `bin/test_curl.sh` which enforces timeouts and logging.
2.  **TIMEOUTS:** All commands interacting with the server or DB must have a timeout (`timeout 3` or `curl --max-time 3`).
3.  **NO DATA LOSS:** Never use `rm -rf` to clear directories. Move them to `.tmp/` with a timestamp: `mv dir .tmp/dir.YYYYMMDD_HHMMSS`.
4.  **LOGGING:** All test runs must log stdout/stderr to `.tmp/logs/YYYYMMDD_HHMMSS/`.

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

**3. Load/Reset Schema:**
Loads the application schema into the `conduit` database.
```bash
mariadb -u root -proot -h 127.0.0.1 -P 3306 --skip-ssl conduit < app/schema.sql
```

**4. Connect via Client:**
```bash
mariadb -u root -proot -h 127.0.0.1 -P 3306 --skip-ssl conduit
```

### Config for Application (`app/config.lua`)
The application connects via TCP to localhost forwarded port.
```lua
db = {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "root",
    database = "conduit",
}
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
The "RealWorld Conduit" demo app (using SQLite) must be subjected to parallel load to exercise the full stack (HTTP -> Router -> Controller -> DB -> Coroutines) with tracing enabled.

**Steps:**
1. **Start the Traced Server:**
   ```bash
   ./build/lunet app/main.lua &
   PID=$!
   sleep 2  # Wait for startup
   ```

2. **Run Functional Tests:**
   Verify basic API correctness.
   ```bash
   bin/test_api.sh
   ```

3. **Run Parallel Load Test:**
   Hit the running server with concurrent requests to trigger potential race conditions or reference leaks.
   *Goal:* Verify the server does NOT crash (which would indicate a tracing assertion failure).
   ```bash
   # Example: 50 concurrent connections, 1000 requests
   ab -c 50 -n 1000 http://127.0.0.1:8080/api/tags
   # OR if ab/wrk not available, use a loop
   for i in $(seq 1 50); do curl -s http://127.0.0.1:8080/api/tags >/dev/null & done; wait
   ```

4. **Cleanup:**
   ```bash
   kill $PID
   wait $PID
   ```

If the server crashes during load testing (exit code > 0 or SIGABRT), it is a **CRITICAL FAILURE**. Check logs for `[TRACE]` assertions.

