# Embedding Lunet from a Release SDK

Each release publishes a platform-specific SDK archive alongside `lunet-run`:

- `lunet-linux-amd64-sdk.tar.gz`
- `lunet-macos-sdk.tar.gz`
- `lunet-windows-amd64-sdk.zip`

The SDK lets a native application link Lunet and compile its Lua application
into its own executable. It does not bundle LuaJIT, libuv, or zlib: install
the matching development/runtime libraries for the target platform.

## SDK layout

```text
bin/generate_embed_scripts.lua
examples/sdk_embed/main.c
examples/sdk_embed/app/main.lua
include/lunet.h
include/lunet_exports.h
lib/liblunet-static.a                 # Linux/macOS
lib/lunet-static.lib                  # Windows
LICENSE
README.md                             # this document
README-CN.md
```

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

## C API and lifecycle

`include/lunet.h` exposes an opaque `lunet_runtime_t` and four functions:

1. Call `lunet_runtime_init` once, optionally supplying the executable path
   and `dangerously_skip_loopback_restriction=1`.
2. Call exactly one of `lunet_runtime_run_file` or
   `lunet_runtime_run_embedded`.
3. Inspect the returned API status separately from the output application exit
   code.
4. Always call `lunet_runtime_shutdown` after successful initialization.

The runtime supports one initialization and one application run per process,
because Lunet uses one default Lua state and libuv loop. `run_embedded` accepts
only safe relative entry-script paths and validates the `LUNETPK1` gzip blob
before running it. Loopback-only network binding remains the default; the
dangerous opt-out is explicit in `lunet_runtime_options_t`.

The static core does not include optional database drivers, PAXE, HTTP client,
or release archive extension modules. Ship those separately when an application
uses them.
