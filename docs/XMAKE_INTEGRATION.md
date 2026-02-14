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
- `build/<platform>/<arch>/release/lunet.so` — the Lunet core shared library (also loadable via `require("lunet")`)
- `build/<platform>/<arch>/release/lunet-run` — standalone runner (links against `lunet.so`)
- `build/<platform>/<arch>/release/lunet/*.so` — driver modules (sqlite3, mysql, postgres) that link against `lunet.so`

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

---

## Build Profiles (When to Use Each)

| Profile | Use case | Command |
|---------|----------|---------|
| **Release** | Production, best performance | `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y` |
| **Debug + trace** | Development, catches bugs | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y` |
| **Verbose trace** | Detailed debugging, logs every event | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y -y` |
| **ASan** | Memory bugs (use-after-free, leaks) | `xmake f -c -m debug --lunet_trace=y --asan=y -y` |

**Tip:** Use `-c` to force a clean reconfigure when switching profiles.

---

## CI Setup for Your Project

If your app uses Lunet and you run CI (e.g. GitHub Actions), test with these profiles:

1. **Release** — `--lunet_trace=n --lunet_verbose_trace=n`
2. **Debug trace** — `--lunet_trace=y --lunet_verbose_trace=n`
3. **Verbose trace** — `--lunet_trace=y --lunet_verbose_trace=y`
4. **ASan** — `--asan=y --lunet_trace=y`

This catches most lifecycle and coroutine issues early.

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
