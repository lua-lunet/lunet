# Embedding Lunet from a Release SDK

Each release publishes a platform-specific SDK archive alongside `lunet-run`:

- `lunet-linux-amd64-sdk.tar.gz`
- `lunet-linux-arm64-sdk.tar.gz`
- `lunet-macos-sdk.tar.gz`
- `lunet-windows-amd64-sdk.zip`

The SDK lets a native application link Lunet and compile its Lua application
into its own executable. It does not bundle LuaJIT, libuv, or zlib: install
the matching development/runtime libraries for the target platform.

## What is in the archive

Three kinds of thing: what you **link against**, what you **run** to embed
your scripts, and a **worked example** to start from.

| Thing | Kind | What it is |
|-------|------|------------|
| `lib/liblunet-static.a` (`liblunet-static.lib` on Windows) | link | The static core runtime: Lua state, event loop, the loopback-only socket/timer/fs/signal primitives |
| `include/lunet.h` | link | The embedding API - the contract for everything below; the header's doc comments are the reference |
| `include/lunet_exports.h` | link | Symbol-visibility plumbing; include it, do not read it |
| `bin/generate_embed_scripts.lua` | run | Compiles a Lua application tree into the embeddable header blob (three environment variables, shown below) |
| `examples/sdk_embed/main.c` | example | A minimal host: init, embed, run - copy this file as your starting point |
| `examples/sdk_embed/app/main.lua` | example | The Lua application that example embeds |
| `README.md` / `README-CN.md` | docs | This document |
| `LICENSE` | docs | The licence |

The optional extension modules (`lunet.http`, `lunet.security`, the database
drivers, `lunet.paxe`, `lunet.jsonic`, `lunet.lnt_shared`, `lunet.httpc`) are
NOT in the static core. They ship in the companion runtime archive
(`lunet-<os>.tar.gz`) as Lua loaders beside `lunet-run`, with their type
annotations in `types/` - see
[docs/RELEASE-LAYOUT.md](RELEASE-LAYOUT.md) for that archive's map. An
embedded application that wants them ships the loaders and their cdylibs
beside its own executable.

`generate_embed_scripts.lua` is executed with `xmake lua`; xmake is used only
to run the supplied Lua generator, not to rebuild Lunet. Set its three input
environment variables because xmake does not forward ordinary script arguments
when it executes a standalone file.

## Build an embedded executable

Extract the SDK and generate a C header from your application tree:

```sh
mkdir generated
LUNET_EMBED_SOURCE=examples/sdk_embed/app \
LUNET_EMBED_OUTPUT=generated/lunet_embed_scripts_blob.h \
LUNET_EMBED_PROJECT_ROOT="$PWD" \
xmake lua bin/generate_embed_scripts.lua
```

On Linux, with the LuaJIT, libuv, and zlib development packages installed:

```sh
cc -std=c99 -Iinclude -Igenerated \
  $(pkg-config --cflags luajit libuv zlib) \
  examples/sdk_embed/main.c lib/liblunet-static.a \
  $(pkg-config --libs luajit libuv zlib) -pthread -ldl -lm \
  -o my-lunet-app
./my-lunet-app
```

On macOS, with Homebrew `luajit`, `libuv`, `zlib`, and `pkg-config` installed:

```sh
export PKG_CONFIG_PATH="$(brew --prefix zlib)/lib/pkgconfig:$PKG_CONFIG_PATH"
cc -std=c99 -Iinclude -Igenerated \
  $(pkg-config --cflags luajit libuv zlib) \
  examples/sdk_embed/main.c lib/liblunet-static.a \
  $(pkg-config --libs luajit libuv zlib) -o my-lunet-app
./my-lunet-app
```

On Windows, install `luajit:x64-windows`, `libuv:x64-windows`, and
`zlib:x64-windows` with vcpkg, then use the Visual Studio developer prompt:

```powershell
cl /nologo /std:c11 /I include /I generated `
  /I "$env:VCPKG_ROOT\installed\x64-windows\include" `
  examples\sdk_embed\main.c lib\lunet-static.lib /link `
  /LIBPATH:"$env:VCPKG_ROOT\installed\x64-windows\lib" `
  lua51.lib uv.lib zlib.lib ws2_32.lib iphlpapi.lib userenv.lib psapi.lib `
  advapi32.lib user32.lib shell32.lib ole32.lib dbghelp.lib /OUT:my-lunet-app.exe
.\my-lunet-app.exe
```

Name the output after your appliance. The convention used by downstream
projects is `<app>-<os>-<arch>.run` (for example `webdav-linux-amd64.run`):
a single self-contained executable that users run directly, with no
extracted script tree and nothing else installed.

## C API and lifecycle

`include/lunet.h` exposes an opaque `lunet_runtime_t` and six functions,
in three groups:

**Lifecycle** - call in this order:

1. `lunet_runtime_init` - once, optionally supplying the executable path
   and `dangerously_skip_loopback_restriction=1`.
2. Exactly one of `lunet_runtime_run_file` or `lunet_runtime_run_embedded`.
3. `lunet_runtime_shutdown` - always, after successful initialization.

**Control:**

- `lunet_runtime_request_stop` - requests a deliberate stop (the runtime
  passes through the drain point below). This one call is thread-safe: a
  host may call it from another thread while `run_file` / `run_embedded`
  blocks on the runtime thread.

**Introspection:**

- `lunet_runtime_get_lua_state` - the host's escape hatch to the live
  `lua_State*` (the embed example uses it to set up globals like `arg`
  before the entry script runs). Returns `NULL` for a `NULL` runtime.

Inspect the returned API status separately from the output application exit
code. The runtime supports one initialization and one application run per
process, because Lunet uses one default Lua state and libuv loop.
`run_embedded` accepts only safe relative entry-script paths and validates
the `LUNETPK1` gzip blob before running it. Loopback-only network binding
remains the default; the dangerous opt-out is explicit in
`lunet_runtime_options_t`.

## Deliberate stop, drain point, and the post-drain hook

A running application can request termination itself (`lunet.stop()`), or the
host can request it from C with `lunet_runtime_request_stop`. The semantics:

- the event loop stops taking new work immediately (`uv_stop` ends the
  current iteration; no new accepts/reads proceed past it);
- work already accepted keeps running; whatever is still parked when the
  loop is stopped is abandoned safely: a pending sleep timer never fires
  again and its coroutine is never resumed (mirroring the safe-abandon rule
  for outbound writes);
- outbound writes either complete or are abandoned safely;
- at the drain point the registered post-drain Lua callback runs exactly
  once and must do synchronous work only:
  the state in memory is the state here, so the host can persist it (write
  the WAL, record the superblock `flushed` flag).
- after the callback, every remaining handle is closed, the callbacks are
  drained, and `uv_loop_close` runs with its return value checked.

## Creating the post-drain hook

Registered via `lunet.on_stop(fn)` (replaces a previously registered one):

```lua
lunet.on_stop(function()
    -- synchronous only: the loop is not driving anything here
    wal.write(state)
    superblock.write_flag("flushed")
end)
lunet.stop()
```

So the lifecycle the host builds: `running` before the loop starts, `stopping`
when termination is requested, `flushed` inside the post-drain hook. On the
next start, `flushed` means the previous process ended cleanly; anything
earlier means it died mid-shutdown and the WAL must be replayed.

The static core does not include optional database drivers, PAXE, HTTP client,
or release archive extension modules. Ship those separately when an application
uses them.
