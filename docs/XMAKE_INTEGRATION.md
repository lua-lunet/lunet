# Integrating Lunet into Your Project

This guide helps you build and use Lunet in your own application. No prior xmake experience required.

## What is xmake?

Lunet uses **xmake** as its build system. xmake is a lightweight, cross-platform build tool (similar to CMake or Make). You don't need to learn xmake in depth—just follow the commands below.

**Install xmake:**

```bash
# Linux / macOS (curl)
curl -fsSL https://xmake.io/install.sh | bash

# Or via package manager
# macOS: brew install xmake
# Ubuntu: add-apt-repository ppa:xmake-io/xmake && apt install xmake
```

## Quick Start: Build Lunet

### 1. Clone and build

```bash
git clone https://github.com/lua-lunet/lunet.git
cd lunet
xmake f -m release --lunet_trace=n --lunet_verbose_trace=n -y
xmake build
```

**What this does:**
- `xmake f` = configure
- `-m release` = optimized build (fast, smaller binary)
- `--lunet_trace=n` = no debug tracing (recommended for production)
- `-y` = accept defaults without prompting

**Output files:**
- `build/<platform>/<arch>/release/lunet.so` — the Lua module
- `build/<platform>/<arch>/release/lunet-run` — standalone runner

### 2. Run your app with lunet-run

```bash
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" path/to/your_app.lua
```

### 3. Or load lunet.so from plain LuaJIT

If you prefer to use `luajit` directly:

```bash
export LUA_CPATH="$(pwd)/build/$(xmake l print(os.host()))/$(xmake l print(os.arch()))/release/?.so;;"
luajit -e 'local lunet=require("lunet"); print(type(lunet))'
```

---

## Build Profiles (When to Use Each)

| Profile | Use case | Command |
|---------|----------|---------|
| **Release** | Production, best performance | `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y` |
| **Debug + trace** | Development, catches bugs | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y` |
| **Verbose trace** | Detailed debugging, logs every event | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y -y` |
| **ASan** | Memory bugs (use-after-free, leaks) | `xmake f -c -m debug --lunet_trace=y --asan=y -y` |
| **EasyMem release** | Production with arena allocator | `xmake f -c -m release --easy_memory=y -y` |
| **EasyMem debug** | Full diagnostics + arena profiling | `xmake f -c -m debug --lunet_trace=y --easy_memory=y -y` |
| **ASan + EasyMem** | Maximum coverage (auto-enabled) | `xmake f -c -m debug --lunet_trace=y --asan=y -y` |

**Tip:** Use `-c` to force a clean reconfigure when switching profiles.

---

## EasyMem/easy_memory (Experimental Arena Allocator)

Lunet optionally integrates [EasyMem/easy_memory](https://github.com/EasyMem/easy_memory) for richer memory diagnostics, arena-scoped allocation, and cross-platform safety checks that go beyond what ASan alone provides.

### Opting In

Pass `--easy_memory=y` to `xmake f`:

```bash
# Release build with easy_memory
xmake f -c -m release --easy_memory=y -y
xmake build

# Debug build with full diagnostics
xmake f -c -m debug --lunet_trace=y --easy_memory=y -y
xmake build
```

Or use the Makefile shortcuts:

```bash
make build-easy-memory        # Release with easy_memory
make build-debug-easy-memory  # Debug + trace + easy_memory (full diagnostics)
```

### What Gets Enabled

When `--easy_memory=y` is set:

| Build mode | Defines | Behavior |
|------------|---------|----------|
| **Release** (`-m release`) | `LUNET_EASY_MEMORY`, `EM_SAFETY_POLICY=1` | Defensive mode. Graceful `NULL` on misuse. Arena available. |
| **Debug + trace** | `LUNET_EASY_MEMORY`, `EM_ASSERT_STAYS`, `EM_POISONING`, `EM_SAFETY_POLICY=0` | Contract mode. Assertions always on. Freed memory poisoned. Crashes on misuse. |
| **ASan** (`--asan=y`) | Same as debug + trace | EasyMem is **auto-enabled** when ASan is active. No need to pass `--easy_memory=y` separately. |

### Profiling Output

At shutdown, the EasyMem integration prints a profiling summary to stderr:

```
========================================
       EASY_MEMORY PROFILING SUMMARY
========================================
Allocations:
  Total allocs:   0
  Total frees:    0
  ...
Worker Arenas:
  Created:        0
  Destroyed:      0
Arena Config:
  Arena size:     16777216 bytes
  Poisoning:      ENABLED
  Assertions:     ALWAYS ON (EM_ASSERT_STAYS)
========================================
```

### Worker Arenas for DB Drivers

The integration provides scoped nested arenas for database driver thread-pool callbacks:

```c
#include "lunet_easy_memory.h"

void db_query_work(uv_work_t *req) {
    EM *arena = lunet_em_worker_arena_begin(64 * 1024);  // 64KB
    // ... allocate temp buffers from arena ...
    lunet_em_worker_arena_end(arena);  // O(1) cleanup
}
```

This is particularly useful for SQLite3/MySQL/PostgreSQL drivers where query execution allocates temporary buffers that should be freed in bulk when the work function returns.

### Disabling

To build without easy_memory (the default):

```bash
xmake f -c --easy_memory=n -y
```

Or simply omit the flag — easy_memory is opt-in except when ASan is active.

For full details, see [EASY_MEMORY_REPORT.md](EASY_MEMORY_REPORT.md).

---

## CI Setup for Your Project

If your app uses Lunet and you run CI (e.g. GitHub Actions), test with these profiles:

1. **Release** — `--lunet_trace=n --lunet_verbose_trace=n`
2. **Debug trace** — `--lunet_trace=y --lunet_verbose_trace=n`
3. **Verbose trace** — `--lunet_trace=y --lunet_verbose_trace=y`
4. **ASan** — `--asan=y --lunet_trace=y` (auto-enables easy_memory)
5. **EasyMem debug** — `--lunet_trace=y --easy_memory=y` (arena diagnostics without ASan overhead)

This catches most lifecycle, coroutine, and memory issues early.

---

## Optional: LuaJIT + Lunet ASan (macOS)

For deep memory debugging (LuaJIT + Lunet both instrumented), use the macOS-only helpers:

```bash
make luajit-asan
make build-debug-asan-luajit
make repro-50-asan-luajit
```

LuaJIT version pins are in `xmake.lua`. Override if needed:

```bash
xmake f --luajit_snapshot=2.1.0+openresty20250117 --luajit_debian_version=2.1.0+openresty20250117-2 -y
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `xmake: command not found` | Install xmake (see "What is xmake?" above) |
| `libuv not found` | Install: `apt install libuv1-dev` (Linux), `brew install libuv` (macOS) |
| `luajit not found` | Install: `apt install libluajit-5.1-dev` (Linux), `brew install luajit` (macOS) |
| Build fails after changing options | Run `xmake f -c -y` then reconfigure |
| Wrong architecture | Use `xmake f -a arm64` (or `x64`) to target a specific arch |

---

## Performance Note

Debug tracing adds roughly **7–8%** overhead in typical workloads. Use release builds (`--lunet_trace=n`) for production.
