
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
5.  **MANDATORY LOCAL CI PARITY BEFORE PUSH:** Before any push, agents MUST run locally all steps from `.github/workflows/build.yml` for their current OS matrix entry (Linux/macOS/Windows), including configure, build, and packaging commands. If any required step cannot be run locally or fails, do not push until fixed or explicitly approved by the user.

## Release Quality Gate (STRICT)

Before creating or announcing a release:

1. **Tag-triggered CI only:** Release tags (`v*`) must go through GitHub Actions builds (Linux/macOS/Windows). Do not handcraft a release from local output.
2. **Assets required:** The release must include all three archives:
   - `lunet-linux-amd64.tar.gz`
   - `lunet-macos.tar.gz`
   - `lunet-windows-amd64.zip`
3. **Readable release notes:** Notes must include at minimum:
   - `## Highlights`
   - `## Binaries`
   - `## Quick Start`
4. **Verify before sign-off:** Check the published release page and confirm notes formatting plus all assets are present.
5. **If anything is missing:** Fix workflow/release and republish before telling downstream users to consume the tag.

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

## C Code Conventions (STRICT)

This section defines naming conventions and safety rules for C code. These are enforced by `xmake lint`.

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
3. **Run lint**: `xmake lint` must pass (no direct `_lunet_*` calls)
4. **Test with tracing**: `xmake stress` (builds with `LUNET_TRACE=ON`)
5. **Crash is good**: If tracing asserts fail, you found a bug - fix it before release
6. **Release build**: `xmake release` runs tests + stress + optimized build

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
xmake lint     # Check naming conventions (no _lunet_* leaks)
xmake stress   # Debug build + concurrent stress test (must pass)
xmake release  # Full release build (runs test + stress first)
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

## Debugging Methodology: Memory Corruption & Segfaults

This section documents the tools and techniques used to debug runtime crashes in lunet. The codebase has a layered debugging strategy — use them in order of increasing cost.

### Level 1: Domain Tracing (fprintf bisection)

Every module has `*_TRACE_*` macros guarded by `#ifdef LUNET_TRACE_VERBOSE`. These print to stderr with zero cost in release builds.

**How to use:**
```bash
xmake f -c -y --lunet_trace=y --lunet_verbose_trace=y
xmake build lunet-bin
```

Then run your repro and inspect stderr. The trace shows every socket/timer/fs/udp/signal operation with pointer values. When the log cuts off abruptly, the crash is between the last printed line and the next operation.

**Bisection technique:** If you know the crash is between line A and line B, add `fprintf(stderr, ...)` prints at the midpoint, rebuild, and re-run. Repeat until you identify the exact C line. Example from Issue #50:
1. `SOCKET_TRACE_READ` printed → crash is after the READ macro
2. Added `READ_CB_RESOLVE` (before `lua_rawgeti`) and `READ_CB_GOT_REF` (after) → `READ_CB_RESOLVE` printed but `READ_CB_GOT_REF` did not → crash is inside `lua_rawgeti`

### Level 2: Coroutine Resume Tracing

The `lunet_co_resume()` wrapper in `src/co.c` has `[CO_TRACE] RESUME` / `[CO_TRACE] RESUMED` prints (guarded by `LUNET_TRACE_VERBOSE`). These prove whether a crash is inside `lua_resume` itself or in the setup code before it.

### Level 3: Address Sanitizer (ASan)

ASan instruments every memory read/write. It catches use-after-free, buffer overflow, stack overflow, and gives exact stack traces with source lines.

**How to use:**
```bash
xmake f -c -y -m debug --lunet_trace=y --asan=y
xmake build lunet-bin
```

The `--asan` option adds `-fsanitize=address -fno-omit-frame-pointer` to the lunet-bin target. When a memory error is detected, ASan prints a detailed report to stderr including:
- The type of error (SEGV, heap-use-after-free, heap-buffer-overflow, etc.)
- The exact address and register values
- A full backtrace with source file/line numbers
- For UAF: both the access stack trace AND the deallocation stack trace

**Important:** ASan's output goes to stderr, so check your log files. The process exits with `Abort trap: 6` (SIGABRT) instead of `Segmentation fault: 11`.

**Limitations:** ASan links against the system LuaJIT dylib, so LuaJIT-internal frames may show as `lua_rawgeti+0x14` without source info. Our C functions may be inlined and missing from the trace. Register values (`x[0]` through `x[28]` on arm64) are still useful — `x[0]` is usually the first function argument.

### Level 4: Memory Tracing (lunet_mem)

The `lunet_mem.h` / `lunet_mem.c` layer wraps `malloc`/`free` with:
- **Canary headers**: Magic bytes before each allocation to detect overflows
- **Poison-on-free**: Freed memory is filled with `0xDE` bytes to make UAF crashes more obvious
- **Global counters**: `alloc_count` / `free_count` checked at shutdown for leaks

Enabled by `LUNET_TRACE`. Use `lunet_alloc()` / `lunet_free()` instead of raw `malloc` / `free`.

### Level 5: lldb / Core Dumps

For interactive debugging:
```bash
lldb -b -o "run app/your_script.lua" -o "bt" -o "bt all" -o "quit" -- ./build/macosx/arm64/debug/lunet-run
```

For core dumps on macOS (SIP may interfere):
```bash
ulimit -c unlimited
# run crash, then:
lldb ./build/macosx/arm64/debug/lunet-run -c /cores/core.XXXXX
```

### Repro Harness

The socket stress test lives in `.tmp/repro-payload/`:
```bash
LUNET_BIN="$(pwd)/build/macosx/arm64/debug/lunet-run" \
  ITERATIONS=5 REQUESTS=20 CONCURRENCY=2 WORKERS=2 \
  timeout 30 .tmp/repro-payload/scripts/repro.sh
```

Logs go to `.tmp/repro-payload/.tmp-repro-logs/{dmz,echo,load}.log`.

### Known Pitfalls

- **Dangling `lua_State*` in long-lived handles**: Never store the *calling coroutine* `lua_State*` in a socket/udp handle and later use it for registry ops. The setup coroutine can finish synchronously and be GC'ed, leaving a dangling pointer that crashes in callbacks (often inside `lua_rawgeti`). Store the owning main state (`default_luaL()` at creation time) and use corefs to track the waiting coroutine.
- **libuv handle adjacency**: Keep libuv handle memory away from critical metadata like `lua_State*`. If anything writes past the handle boundary (ABI mismatch, out-of-bounds, or teardown edge cases), it should not corrupt control pointers. Prefer placing the handle at the end of the struct and/or add a tail canary in trace builds.
- **Coroutine GC**: Spawned coroutines must be anchored in the Lua registry (via `lunet_co_anchor()`) or they can be garbage collected between async operations.
- **`ctx->co` is shared**: All accepted client sockets inherit `ctx->co` from the listener. This should be the owning **main** Lua state pointer (not the listener coroutine). If it becomes invalid, every socket callback that touches the registry will crash.
- **Release vs debug divergence**: Some bugs only appear in release builds (e.g., duplicate `trace_summary` definitions caused by `static inline` in headers conflicting with definitions in `.c` files). Always test both `xmake f -m release` and `xmake f -m debug`.

## Scripting Guidelines

**AVOID SHELL SCRIPTS FOR NON-TRIVIAL WORK.**

This is a **Lua** project. If a task requires logic, loops, parsing, or file manipulation beyond simple command chaining, **write it in Lua**.

*   **Allowed in Shell:** Simple wrappers (e.g., `xmake` targets), environment setup, `curl` tests.
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
xmake build-debug  # Includes -DLUNET_TRACE=ON
```

### 2. Run Stress Tests
Before testing the application logic, ensure the core runtime is stable under load.

```bash
xmake stress
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
2. Build with `xmake build-debug` to enable tracing
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
