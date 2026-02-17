# Downstream Project Workflow Alignment

[中文文档](DOWNSTREAM_WORKFLOW-CN.md)

This guide explains how downstream Lunet applications (for example, `lunet-realworld-example-app`) should align with Lunet's workflow without copying upstream tasks one-to-one.

## Why this guide exists

`xmake ci` and `xmake release` in this repository are **upstream-maintainer tasks**. They assume Lunet's internal layout (`test/`, `spec/`, `examples/`, and Lunet-specific smoke/stress scripts).

Downstream applications usually have different test assets (API scripts, integration fixtures, app packaging logic), so they should define app-specific tasks that preserve the same quality gate intent.

## Task mapping: upstream -> downstream

| Upstream task (this repo) | Purpose | Downstream equivalent |
|---|---|---|
| `xmake ci` | Local CI parity for Lunet core | `xmake app-ci` |
| `xmake release` | Full release gate for Lunet core | `xmake app-release` |
| `xmake preflight-easy-memory` | Debug/ASan/EasyMem preflight | `xmake app-preflight` |
| `xmake examples-compile`, `xmake sqlite3-smoke` | Upstream example checks | `xmake app-smoke`, `xmake app-api-test`, etc. |

Recommended rule: keep upstream names for Lunet itself, and use an `app-` prefix for downstream project gates.

## Recommended downstream repository layout

```text
my-lunet-app/
  xmake.lua
  deps/
    lunet/                  # optional submodule/subtree/clone
  app/
    main.lua
  scripts/
    smoke.sh
    api_test.sh
    package.sh
  .tmp/
    logs/
```

## xmake.lua scaffold for downstream tasks

Use this as a template and replace commands with your own test/package steps:

```lua
set_project("my-lunet-app")
set_languages("c99")
add_rules("mode.debug", "mode.release")

includes("deps/lunet")

local function app_new_logdir(suite)
    local stamp = os.date("%Y%m%d_%H%M%S")
    local dir = path.join(".tmp", "logs", stamp, suite)
    os.mkdir(dir)
    return dir
end

local function app_exec_logged(logdir, step, command)
    local logfile = path.join(logdir, step .. ".log")
    os.exec("bash -lc \"" .. command .. " > " .. logfile .. " 2>&1\"")
end

task("app-smoke")
    set_menu {usage = "xmake app-smoke", description = "Fast downstream smoke checks"}
    on_run(function ()
        local logdir = app_new_logdir("app_smoke")
        app_exec_logged(logdir, "01_smoke", "timeout 30 ./scripts/smoke.sh")
        print("app-smoke logs: " .. logdir)
    end)
task_end()

task("app-api-test")
    set_menu {usage = "xmake app-api-test", description = "API/integration tests"}
    on_run(function ()
        local logdir = app_new_logdir("app_api_test")
        app_exec_logged(logdir, "01_api", "timeout 120 ./scripts/api_test.sh")
        print("app-api-test logs: " .. logdir)
    end)
task_end()

task("app-preflight")
    set_menu {usage = "xmake app-preflight", description = "Debug+ASan preflight gate"}
    on_run(function ()
        local logdir = app_new_logdir("app_preflight")
        app_exec_logged(logdir, "01_configure", "xmake f -c -m debug --lunet_trace=y --asan=y -y")
        app_exec_logged(logdir, "02_build", "xmake build")
        app_exec_logged(logdir, "03_smoke", "timeout 30 ./scripts/smoke.sh")
        app_exec_logged(logdir, "04_api", "timeout 120 ./scripts/api_test.sh")
        print("app-preflight logs: " .. logdir)
    end)
task_end()

task("app-ci")
    set_menu {usage = "xmake app-ci", description = "Downstream CI gate"}
    on_run(function ()
        os.exec("xmake lint")
        os.exec("xmake build-release")
        os.exec("xmake app-smoke")
        os.exec("xmake app-api-test")
    end)
task_end()

task("app-release")
    set_menu {usage = "xmake app-release", description = "Downstream release gate"}
    on_run(function ()
        os.exec("xmake app-ci")
        os.exec("xmake app-preflight")
        os.exec("timeout 60 ./scripts/package.sh")
    end)
task_end()
```

## Integrating shell-based tests safely

For downstream repos that use shell scripts for API/load tests:

1. Run scripts via xmake tasks (`app-smoke`, `app-api-test`, `app-preflight`).
2. Apply explicit timeouts (`timeout 30`, `timeout 120`, etc.).
3. Persist logs under `.tmp/logs/YYYYMMDD_HHMMSS/<suite>/`.
4. Keep shell wrappers thin; put non-trivial orchestration logic in Lua where practical.

## `os.projectdir()` vs `os.scriptdir()` in subproject setups

When Lunet is included as a subproject, path resolution can fail if tasks assume the top-level project root.

Use this rule in downstream code:

- Prefer `os.scriptdir()` for locating files relative to the current `xmake.lua`.
- If invoking Lunet-maintained scripts/tasks, call them with explicit `curdir` pointing to the Lunet checkout.

Example:

```lua
local app_root = os.scriptdir()
local lunet_root = path.join(app_root, "deps", "lunet")
local lint_script = path.join(lunet_root, "bin", "lint_c_safety.lua")
os.execv("xmake", {"lua", lint_script}, {curdir = lunet_root})
```

This avoids fragile symlink-only workarounds and keeps downstream integration reproducible.

## CI recommendation for downstream repos

At minimum, run these in your downstream CI:

```bash
xmake app-ci
xmake app-preflight
```

For tagged releases, add:

```bash
xmake app-release
```

## Reference implementation

The canonical downstream application is:

- https://github.com/lua-lunet/lunet-realworld-example-app

Use it as the baseline for evolving `app-ci` and `app-release` patterns.
