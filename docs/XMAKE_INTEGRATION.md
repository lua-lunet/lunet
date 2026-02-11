# Canonical xmake Integration Guide (Downstream Apps)

This guide is for downstream applications embedding or consuming Lunet with `xmake`.

## 1) Clone and build Lunet once

```bash
git clone https://github.com/lua-lunet/lunet.git
cd lunet
xmake f -m release --lunet_trace=n --lunet_verbose_trace=n -y
xmake build
```

Build outputs:

- `build/<plat>/<arch>/release/lunet.so`
- `build/<plat>/<arch>/release/lunet-run`

## 2) Run an app with `lunet-run`

```bash
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" path/to/app.lua
```

## 3) Load `lunet.so` from plain LuaJIT

Set `LUA_CPATH` to the built module directory:

```bash
export LUA_CPATH="$(pwd)/build/$(xmake l print(os.host()))/$(xmake l print(os.arch()))/release/?.so;;"
luajit -e 'local lunet=require("lunet"); print(type(lunet))'
```

If your app has its own loader logic, add Lunet's build directory to that loader path.

## 4) Canonical build profiles

### Release (zero debug tax)

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y
xmake build
```

### Debug tracing (bookkeeping + assertions)

```bash
xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y
xmake build
```

### Verbose tracing (per-event logs)

```bash
xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y -y
xmake build
```

### ASan (Lunet C code)

```bash
xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y --asan=y -y
xmake build lunet-bin
```

## 5) LuaJIT + Lunet ASan (macOS only)

The helper targets are macOS-only and fail fast on non-Darwin hosts.

```bash
make luajit-asan
make build-debug-asan-luajit
make repro-50-asan-luajit
```

LuaJIT source package pins are configured in `xmake.lua` options:

- `luajit_snapshot`
- `luajit_debian_version`

Override pins:

```bash
xmake f --luajit_snapshot=2.1.0+openresty20250117 --luajit_debian_version=2.1.0+openresty20250117-2 -y
```

## 6) Minimal downstream CI matrix

Recommended CI profiles for downstream projects:

1. Release (`--lunet_trace=n --lunet_verbose_trace=n`)
2. Debug trace (`--lunet_trace=y --lunet_verbose_trace=n`)
3. Debug verbose trace (`--lunet_trace=y --lunet_verbose_trace=y`)
4. ASan debug (`--asan=y --lunet_trace=y`)

This catches most lifecycle and coroutine bookkeeping failures early, while keeping production builds lean.

