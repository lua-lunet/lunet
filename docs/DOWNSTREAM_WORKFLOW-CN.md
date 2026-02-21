# 下游项目工作流对齐指南

[English Documentation](DOWNSTREAM_WORKFLOW.md)

本指南说明下游 Lunet 应用（例如 `lunet-realworld-example-app`）如何与 Lunet 的工作流对齐，而不是机械复制上游任务。

## 为什么需要这份指南

本仓库中的 `xmake ci` 与 `xmake release` 是**上游维护者任务**，默认依赖 Lunet 内部目录结构（`test/`、`spec/`、`examples/` 以及 Lunet 专用的 smoke/stress 脚本）。

下游应用通常有不同的测试资产（API 脚本、集成测试夹具、应用打包逻辑），因此应定义自己的应用级任务，同时保持质量门控目标一致。

## 任务映射：上游 -> 下游

| 上游任务（本仓库） | 目的 | 下游等价任务 |
|---|---|---|
| `xmake ci` | Lunet 核心的本地 CI 一致性 | `xmake app-ci` |
| `xmake release` | Lunet 核心完整发布门控 | `xmake app-release` |
| `xmake preflight-easy-memory` | Debug/ASan/EasyMem 预检 | `xmake app-preflight` |
| `xmake examples-compile`、`xmake sqlite3-smoke` | 上游示例检查 | `xmake app-smoke`、`xmake app-api-test` 等 |

推荐规则：Lunet 上游继续使用原任务名；下游项目统一使用 `app-` 前缀定义门控任务。

## 推荐的下游仓库结构

```text
my-lunet-app/
  xmake.lua
  deps/
    lunet/                  # 可选：submodule/subtree/独立克隆
  app/
    main.lua
  scripts/
    smoke.sh
    api_test.sh
    package.sh
  .tmp/
    logs/
```

## 下游任务的 xmake.lua 模板

可基于以下模板按需替换测试/打包命令：

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
    set_menu {usage = "xmake app-smoke", description = "快速下游冒烟检查"}
    on_run(function ()
        local logdir = app_new_logdir("app_smoke")
        app_exec_logged(logdir, "01_smoke", "timeout 30 ./scripts/smoke.sh")
        print("app-smoke logs: " .. logdir)
    end)
task_end()

task("app-api-test")
    set_menu {usage = "xmake app-api-test", description = "API/集成测试"}
    on_run(function ()
        local logdir = app_new_logdir("app_api_test")
        app_exec_logged(logdir, "01_api", "timeout 120 ./scripts/api_test.sh")
        print("app-api-test logs: " .. logdir)
    end)
task_end()

task("app-preflight")
    set_menu {usage = "xmake app-preflight", description = "Debug+ASan 预检门控"}
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
    set_menu {usage = "xmake app-ci", description = "下游 CI 门控"}
    on_run(function ()
        os.exec("xmake lint")
        os.exec("xmake build-release")
        os.exec("xmake app-smoke")
        os.exec("xmake app-api-test")
    end)
task_end()

task("app-release")
    set_menu {usage = "xmake app-release", description = "下游发布门控"}
    on_run(function ()
        os.exec("xmake app-ci")
        os.exec("xmake app-preflight")
        os.exec("timeout 60 ./scripts/package.sh")
    end)
task_end()
```

## 安全集成基于 shell 的测试

对于使用 shell 脚本执行 API/负载测试的下游仓库：

1. 通过 xmake 任务统一调度脚本（`app-smoke`、`app-api-test`、`app-preflight`）。
2. 所有脚本加显式超时（如 `timeout 30`、`timeout 120`）。
3. 日志统一写入 `.tmp/logs/YYYYMMDD_HHMMSS/<suite>/`。
4. shell 包装保持轻量；复杂编排优先使用 Lua 实现。

## 子项目场景中的 `os.projectdir()` 与 `os.scriptdir()`

当 Lunet 作为子项目被引入时，如果任务假设顶层项目根目录，路径解析可能失败。

下游代码建议遵循：

- 用 `os.scriptdir()` 定位当前 `xmake.lua` 相对路径。
- 调用 Lunet 维护的脚本/任务时，使用显式 `curdir` 指向 Lunet 目录。

示例：

```lua
local app_root = os.scriptdir()
local lunet_root = path.join(app_root, "deps", "lunet")
local lint_script = path.join(lunet_root, "bin", "lint_c_safety.lua")
os.execv("xmake", {"lua", lint_script}, {curdir = lunet_root})
```

这比仅依赖符号链接的临时方案更稳健，也更易复现。

## 下游仓库的 CI 建议

下游 CI 至少执行：

```bash
xmake app-ci
xmake app-preflight
```

对发布标签再增加：

```bash
xmake app-release
```

## 参考实现

规范的下游应用仓库：

- https://github.com/lua-lunet/lunet-realworld-example-app

可将其作为演进 `app-ci` 与 `app-release` 任务模式的基准。
