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

### 1b. Optional native modules

Lunet ships optional native modules as separate xmake targets. Build only what you need.

Examples:

```bash
# Database drivers
xmake build lunet-sqlite3
xmake build lunet-mysql
xmake build lunet-postgres

# Outbound HTTPS client (libcurl)
xmake build lunet-httpc
```

### 2. Run your app with lunet-run

```bash
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" path/to/your_app.lua
```

### 2b. Optional: Embed Lua scripts into lunet-run

For deployments where Lua source should not live on disk, enable script embedding in release builds:

```bash
xmake f -c -m release --lunet_embed_scripts=y --lunet_embed_scripts_dir=lua -y
xmake build lunet-bin
```

When enabled, `lunet-run` extracts the embedded script tree into a private temp directory at startup and prepends that location to `package.path` and `package.cpath`.

### 3. Or load lunet.so from plain LuaJIT

If you prefer to use `luajit` directly:

```bash
export LUA_CPATH="$(pwd)/build/$(xmake l print(os.host()))/$(xmake l print(os.arch()))/release/?.so;;"
luajit -e 'local lunet=require("lunet"); print(type(lunet))'
```

### 4. Use Lunet as an xmake subproject

If your app has its own `xmake.lua`, include Lunet as a subproject and link it
with `add_deps("lunet")`:

```lua
set_project("myapp")
set_languages("c99")
add_rules("mode.debug", "mode.release")

includes("lunet")

add_requires("pkgconfig::luajit", "pkgconfig::libuv")

target("myapp")
    set_kind("binary")
    add_files("src/*.c")
    add_deps("lunet")
    add_packages("luajit", "libuv")
target_end()
```

Lunet keeps the Lua module output as `lunet.so` and also emits a compatibility
`liblunet.so` for toolchains that link dependencies via `-l<name>`.

## Downstream task patterns (`app-ci`, `app-release`, `app-preflight`)

If you are integrating Lunet into an application repository, do not copy Lunet's
upstream `xmake ci`/`xmake release` tasks directly. Those tasks assume this
repository's internal tests and examples.

For downstream projects, define app-scoped gates:

- `xmake app-ci` for lint + build + app smoke/integration checks
- `xmake app-preflight` for debug/ASan pre-release validation
- `xmake app-release` for app-ci + app-preflight + packaging

For a concrete scaffold (including shell-test wiring, logs, timeouts, and
`os.scriptdir()` guidance for subproject paths), see
[Downstream Project Workflow Alignment](DOWNSTREAM_WORKFLOW.md).

---

## Build Profiles (When to Use Each)

| Profile | Use case | Command |
|---------|----------|---------|
| **Release** | Production, best performance | `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y` |
| **Debug + trace** | Development, catches bugs | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y` |
| **Verbose trace** | Detailed debugging, logs every event | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y -y` |
| **ASan + EasyMem** | Memory bugs (ASan + allocator integrity diagnostics) | `xmake f -c -m debug --lunet_trace=y --asan=y -y` |
| **Experimental EasyMem Release** | Release binary with allocator diagnostics | `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory_experimental=y --easy_memory_arena_mb=128 -y` |

**Tip:** Use `-c` to force a clean reconfigure when switching profiles.

---

## CI Setup for Your Project

If your app uses Lunet and you run CI (e.g. GitHub Actions), test with these profiles:

1. **Release** — `--lunet_trace=n --lunet_verbose_trace=n`
2. **Debug trace** — `--lunet_trace=y --lunet_verbose_trace=n`
3. **Verbose trace** — `--lunet_trace=y --lunet_verbose_trace=y`
4. **ASan + EasyMem** — `--asan=y --lunet_trace=y`

This catches most lifecycle and coroutine issues early.

---

## Local Preflight Safety Gate (run before pushing)

Use the built-in EasyMem preflight task to run the same fast leak/smoke checks locally that CI uses for the EasyMem+ASan profile:

```bash
xmake preflight-easy-memory
```

What it does:
- configures `debug + trace + ASan + EasyMem`
- builds `lunet-bin` and DB modules (MySQL/Postgres optional if deps are missing locally)
- runs `test/ci_easy_memory_db_stress.lua`
- runs `test/ci_easy_memory_lsan_regression.lua`
- writes all step logs to `.tmp/logs/YYYYMMDD_HHMMSS/easy_memory_preflight/`

---

## EasyMem Opt-In Modes

Lunet supports [EasyMem/easy_memory](https://github.com/EasyMem/easy_memory) as an allocator backend.

### Automatic enablement

EasyMem is enabled automatically when either of these is enabled:
- `--lunet_trace=y`
- `--asan=y`

### Manual opt-in

Enable EasyMem explicitly without enabling trace:

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory=y -y
xmake build
```

### Experimental release mode

Enable full diagnostics in release for allocator analysis:

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory_experimental=y --easy_memory_arena_mb=128 -y
xmake build
```

### Arena sizing

Tune EasyMem arena capacity in MB:

```bash
xmake f --easy_memory_arena_mb=256 -y
```

Default is `128` MB (minimum clamped to `8` MB).

---

## Optional: LuaJIT + Lunet ASan (macOS)

For deep memory debugging (LuaJIT + Lunet both instrumented), use the macOS-only helpers:

```bash
xmake luajit-asan
xmake build-debug-asan-luajit
xmake repro-50-asan-luajit
```

These helpers configure `--asan=y --lunet_trace=y`, so EasyMem is also enabled automatically.

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
| `--asan=y` fails on a specific Windows toolchain | Ensure your MSVC/clang-cl version supports `/fsanitize=address` |

---

## Performance Note

Debug tracing adds roughly **7–8%** overhead in typical workloads. Use release builds (`--lunet_trace=n`) for production.
