# Downstream Project Workflow Guide

[中文文档](DOWNSTREAM_WORKFLOW-CN.md)

This guide is for projects that **consume** Lunet (as a release archive or
via `includes("lunet")` in xmake) rather than develop Lunet itself. It
covers how to structure your own `xmake.lua`, define app-level CI/release
tasks, and integrate your own test suites.

## Prerequisites

- A downstream project with its own `xmake.lua`
- Lunet available either as a release archive or as a subproject
  (`includes("lunet")`)
- Your app's own tests (shell scripts, hurl, busted, or anything else)

## Recommended `xmake.lua` structure

Keep your `xmake.lua` focused on *your* app. Do not replicate Lunet's
build targets — consume the release archive or subproject and layer your
own tasks on top.

```lua
-- Your app's xmake.lua
set_project("my-app")
set_version("1.0.0")

-- If using lunet as a subproject (source builds)
-- includes("lunet")

-- If using a release archive, no xmake targets needed for lunet itself.
-- Just fetch and extract:
--   curl -fsSL https://github.com/lua-lunet/lunet/releases/download/v0.9.1/lunet-linux-amd64.tar.gz | tar -xzf - -C bin

-- Your own app-level tasks below
```

## Defining app-level tasks

xmake tasks are the idiomatic way to define CI, release, and smoke-test
entry points. Unlike Make targets, they run in-process and can compose
other xmake operations.

### `xmake app-ci` — your CI gate

```lua
task("app-ci")
    set_menu { usage = "xmake app-ci", description = "Run all CI checks" }
    on_run(function ()
        -- Lint your app's Lua code (if you have luacheck)
        os.exec("luacheck src/ spec/")

        -- Run your test suite (shell scripts, hurl, etc.)
        os.execv("./scripts/test.sh")

        -- Build any native extensions you ship alongside
        -- os.exec("xmake build my-extension")
    end)
task_end()
```

### `xmake app-smoke` — quick health check

```lua
task("app-smoke")
    set_menu { usage = "xmake app-smoke", description = "Quick smoke test" }
    on_run(function ()
        local lunet = "bin/lunet-run"  -- or wherever you extracted it
        os.execv(lunet, {"test/smoke_app.lua"})
    end)
task_end()
```

### `xmake app-release` — pre-release gate

```lua
task("app-release")
    set_menu { usage = "xmake app-release", description = "Pre-release validation" }
    on_run(function ()
        -- 1. CI checks must pass
        os.exec("xmake app-ci")

        -- 2. Version consistency
        local v = get_config("version") or "dev"
        assert(v ~= "dev", "Set a version: xmake f --version=1.0.0")

        -- 3. Package
        os.exec("./scripts/package.sh")
    end)
task_end()
```

## Integrating shell-based tests

xmake tasks can invoke any command. If your app has shell-based API tests
(hurl, curl scripts, etc.), call them from a task:

```lua
task("app-test")
    set_menu { usage = "xmake app-test", description = "Run API tests" }
    on_run(function ()
        -- Start your app in the background
        local lunet = "bin/lunet-run"
        local pid = os.fork and os.fork()  -- or use os.exec with &
        -- Wait for readiness, run tests, kill
        os.exec("hurl --test tests/api/*.hurl")
    end)
task_end()
```

For a simpler pattern, keep the shell script self-contained (start server,
wait, test, kill) and just invoke it:

```lua
task("app-test")
    on_run(function ()
        os.exec("./scripts/run-api-tests.sh")
    end)
task_end()
```

## Subproject inclusion pitfalls

When using `includes("lunet")` to build from source:

- **`os.scriptdir()` vs `os.projectdir()`**: Lunet's `xmake.lua` uses
  `os.scriptdir()` for internal build scripts so they resolve correctly
  even when included as a subproject. Your own `xmake.lua` should use
  `os.scriptdir()` for the same reason.
- **Build directory**: Subproject outputs land in the *parent* project's
  `build/` directory. `lunet-run` will be at
  `build/<platform>/<arch>/release/lunet-run` regardless of whether
  you're the parent or the subproject.
- **Configuration flags**: Lunet's `xmake f` options (`--lunet_trace=n`,
  etc.) work the same whether it's the root project or a subproject.

## Reference implementation

The
[lunet-realworld-example-app](https://github.com/lua-lunet/lunet-realworld-example-app)
is the canonical downstream consumer. Its `xmake.lua` and
`scripts/` directory are a working reference for the patterns above.

## What NOT to do

- **Don't copy lunet's `xmake.lua` tasks** (`xmake lint`, `xmake test`,
  etc.) into your own project. Those test lunet itself. Define your own.
- **Don't fork lunet's build targets** — use `includes("lunet")` or
  consume the release archive.
- **Don't assume lunet's `test/` directory exists** in your project —
  busted specs are for lunet development, not downstream apps.
