# opt/ — Optional Experimental Modules

The `opt/` directory contains lunet modules for libraries that **do not have official
binary releases** on the platforms lunet supports (Linux via Debian LTS/Trixie,
macOS via Homebrew, Windows via vcpkg).

## How `opt/` differs from `ext/`

| Aspect | `ext/` | `opt/` |
|--------|--------|--------|
| **Platform availability** | Libraries available via system package managers (`apt`, `brew`, `vcpkg`) | Libraries must be vendored/built from source |
| **CI treatment** | Built and tested on every platform; included in release archives | Built and tested in CI but **not** included in release archives |
| **xmake default** | Not default (but simple `xmake build lunet-<name>`) | Not default; each module has its own `xmake opt-<name>` target |
| **Binary releases** | Shipped in `lunet-{linux,macos,windows}` archives | Not shipped — users build from source |
| **Stability** | Wraps mature, LTS-released libraries | Wraps pre-release or niche libraries |

## Current Modules

### GraphLite (`opt/graphlite/`)

An ISO GQL (Graph Query Language) graph database powered by
[GraphLite](https://github.com/GraphLite-AI/GraphLite). GraphLite is an
embeddable graph database written in Rust that implements the ISO GQL standard.

Since GraphLite has no official platform packages, we:

1. Clone the GraphLite repo at a pinned commit
2. Build the `graphlite-ffi` crate using a pinned Rust LTS toolchain
3. Produce `libgraphlite_ffi.so` / `.dylib` / `.dll`
4. Our C99 shim (`opt/graphlite/graphlite.c`) dynamically loads that library at
   runtime via `dlopen`/`LoadLibrary`
5. The Lua module (`require("lunet.graphlite")`) provides the same coroutine
   yield/resume semantics as our SQLite3 driver

**Build:**
```bash
xmake opt-graphlite          # Fetch, build Rust FFI lib, compile C shim
xmake opt-graphlite-example  # Run the example script
```

## Adding New Modules

When adding a new `opt/` module:

1. Create `opt/<name>/` with the C shim and header
2. Add xmake targets `opt-<name>` and `opt-<name>-example`
3. Pin the upstream commit hash in `xmake.lua`
4. Ensure `.gitignore` covers all vendored build artifacts
5. Add a CI step that builds but does **not** package for release
6. Apply the same `lunet_mem.h`, `trace.h`, and ASAN support as core modules
