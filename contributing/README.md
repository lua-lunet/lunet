# Contributing — Developer setup

This directory holds the one-time setup scripts for Lunet developers. The
build system itself lives in `xmake` — this directory only provisions the
host (system packages + Lua QA tools pinned to luajit).

## Quick start

From the repo root:

```
make init
```

`make init` dispatches on `uname -s`:

| OS | What it runs |
|----|--------------|
| macOS (Darwin) | `contributing/macos/Makefile` → `contributing/deps/macos.sh` |
| Linux (Debian/Ubuntu) | `contributing/debian/Makefile` → `contributing/deps/debian.sh` |
| Windows | prints `pwsh contributing\windows\setup.ps1` |

Each per-OS script installs the system dev libraries (matching the list in
`.github/workflows/build.yml`), then execs `contributing/deps/qa-luarocks.sh`
to install the Lua QA rocks (`luafilesystem`, `busted`, `luacheck`) against
the luajit interpreter — not the system Lua.

## Make vs xmake — domain split

- **`make init`** = developer setup. Installs system packages + Lua QA tools.
  Runs once per machine (or when a new dep is added).
- **`xmake build-release`**, **`xmake test`**, **`xmake stress`** = building
  the software. Runs on every change.

`xmake init` remains as the QA-tools-only entry and delegates to the same
`contributing/deps/qa-luarocks.sh` script on Unix.

## Tool versions (mise)

`.mise.toml` at the repo root pins **xmake** (currently `3.0.8`) via the
`github:xmake-io/xmake` backend (xmake is not in mise's core registry). CI
uses the same pin in every `xmake-io/github-action-setup-xmake` step. If you
have [mise](https://mise.jdx.dev/) installed, `mise install` will fetch the
right xmake automatically; otherwise any xmake 3.0.8 on `PATH` works.

Everything else (luajit, luarocks, system dev libraries) comes from the OS
dep scripts under `contributing/deps/`. mise's luajit plugin is broken
(`list-all` fails, no version list), luarocks is not a mise plugin at all,
and xmake itself requires the `github:` backend prefix, so the system path
remains the supported way to provision the Lua toolchain.

## macOS: PKG_CONFIG_PATH

Homebrew's `zlib`, `curl`, `libpq`, and `mysql-client` are keg-only. After
`make init`, the macos script prints the `export PKG_CONFIG_PATH=...` line.
Add it to your shell profile — it is required for the db drivers, httpc,
and `xmake preflight-easy-memory`.

## CI reuse

The same `contributing/deps/*` scripts are also called from CI, so what a
developer runs locally is what the build runners run. The scripts are
idempotent and safe to re-run.

## Troubleshooting

### `luacheck` broken under Homebrew Lua 5.5

luacheck 1.2.0 cannot run under Homebrew's default `lua` 5.5. The
`qa-luarocks.sh` script pins the install to luajit:

```
luarocks --lua-version=5.1 --lua-dir=$(brew --prefix luajit) install luacheck
```

If `luacheck --version` fails, re-run `make init` (or `xmake init`) to
reinstall against the correct interpreter.

### `luajit not found`

Install luajit first:

- macOS: `brew install luajit`
- Debian/Ubuntu: `sudo apt-get install luajit libluajit-5.1-dev`
