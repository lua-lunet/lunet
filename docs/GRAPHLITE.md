# GraphLite Optional Module (`opt/graphlite`)

[中文文档](GRAPHLITE-CN.md)

This document describes Lunet's **optional** GraphLite integration:

- Lua module: `require("lunet.graphlite")`
- Build target: `lunet-graphlite`
- xmake tasks:
  - `xmake opt-graphlite`
  - `xmake opt-graphlite-example`

## Why this lives in `opt/` (not `ext/`)

GraphLite is not currently shipped as a stable system package/release artifact
across all Lunet platforms. Unlike `ext/` modules (which wrap mature platform
libraries), GraphLite is vendored and built from source at a pinned revision.

So this module is CI-tested but **not** included in Lunet's official release
binary archives.

## Pinned Upstream Inputs

- GraphLite repo: `https://github.com/GraphLite-AI/GraphLite.git`
- Pinned commit: `a370a1c909642688130eccfd57c74b6508dcaea5`
- Pinned Rust toolchain: `1.87.0`

These are defined in `xmake.lua`.

## Build Flow

### 1) Build optional GraphLite stack

```bash
xmake opt-graphlite
```

This task:

1. runs `xmake build-release`
2. clones/fetches GraphLite at the pinned commit into `.tmp/opt/graphlite/GraphLite`
3. installs pinned Rust toolchain
4. builds `graphlite-ffi` shared library (`cargo +1.87.0 build --release -p graphlite-ffi`)
5. stages artifacts under:
   - `.tmp/opt/graphlite/install/lib/`
   - `.tmp/opt/graphlite/install/include/`
6. builds `lunet-graphlite`

### 2) Run the optional smoke/example

```bash
xmake opt-graphlite-example
```

This task runs `test/opt_graphlite_example.lua` with:

- `LUA_CPATH` extended to include `build/**/release/opt/?.so` (or `?.dll`)
- `LUNET_GRAPHLITE_LIB` set to staged GraphLite FFI shared library

## Runtime API

`lunet.graphlite` follows Lunet DB driver conventions:

- `db.open(path_or_config)`
- `db.close(conn)`
- `db.query(conn, gql)`
- `db.exec(conn, gql)`
- `db.escape(str)`

Notes:

- `db.query_params` / `db.exec_params` currently reject positional parameters for GraphLite.
- The module dynamically loads GraphLite FFI at runtime (no static link to system GraphLite).
- Connection operations run through libuv worker threads and use mutex-protected handles.

## Paths and Git Hygiene

All vendored GraphLite source/build outputs stay under `.tmp/`, which is already
ignored by git:

- `.tmp/opt/graphlite/GraphLite` (upstream source checkout)
- `.tmp/opt/graphlite/install` (staged shared lib + header)
