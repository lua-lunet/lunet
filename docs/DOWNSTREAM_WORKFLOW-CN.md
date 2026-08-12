# 下游项目工作流指南

[English Documentation](DOWNSTREAM_WORKFLOW.md)

本指南面向**消费** Lunet 的项目（通过发布压缩包或 xmake 的
`includes("lunet")`），而非开发 Lunet 本身。内容涵盖如何组织你自己的
`xmake.lua`、定义应用级 CI/发布任务，以及集成你自己的测试套件。

## 前提条件

- 一个拥有自己 `xmake.lua` 的下游项目
- Lunet 以发布压缩包或子项目（`includes("lunet")`）形式可用
- 你应用自身的测试（shell 脚本、hurl、busted 或其他）

## 推荐的 `xmake.lua` 结构

让你的 `xmake.lua` 聚焦于*你的*应用。不要复制 Lunet 的构建目标——
消费发布压缩包或子项目，在其上叠加你自己的任务。

```lua
-- 你的应用的 xmake.lua
set_project("my-app")
set_version("1.0.0")

-- 如果使用 lunet 作为子项目（源码构建）
-- includes("lunet")

-- 如果使用发布压缩包，lunet 本身不需要 xmake 目标。
-- 只需下载解压：
--   curl -fsSL https://github.com/lua-lunet/lunet/releases/download/v0.9.1/lunet-linux-amd64.tar.gz | tar -xzf - -C bin

-- 你自己的应用级任务见下
```

## 定义应用级任务

xmake 任务是定义 CI、发布和冒烟测试入口的习惯方式。与 Make 目标不同，
它们在进程内运行，可以组合其他 xmake 操作。

### `xmake app-ci` — 你的 CI 门控

```lua
task("app-ci")
    set_menu { usage = "xmake app-ci", description = "运行所有 CI 检查" }
    on_run(function ()
        -- 对你应用的 Lua 代码做静态检查（如果使用 luacheck）
        os.exec("luacheck src/ spec/")

        -- 运行你的测试套件（shell 脚本、hurl 等）
        os.execv("./scripts/test.sh")

        -- 构建你随应用发布的任何原生扩展
        -- os.exec("xmake build my-extension")
    end)
task_end()
```

### `xmake app-smoke` — 快速健康检查

```lua
task("app-smoke")
    set_menu { usage = "xmake app-smoke", description = "快速冒烟测试" }
    on_run(function ()
        local lunet = "bin/lunet-run"  -- 或你解压到的位置
        os.execv(lunet, {"test/smoke_app.lua"})
    end)
task_end()
```

### `xmake app-release` — 发布前门控

```lua
task("app-release")
    set_menu { usage = "xmake app-release", description = "发布前验证" }
    on_run(function ()
        -- 1. CI 检查必须通过
        os.exec("xmake app-ci")

        -- 2. 版本一致性
        local v = get_config("version") or "dev"
        assert(v ~= "dev", "请设置版本号：xmake f --version=1.0.0")

        -- 3. 打包
        os.exec("./scripts/package.sh")
    end)
task_end()
```

## 集成 shell 测试

xmake 任务可以调用任何命令。如果你的应用有基于 shell 的 API 测试
（hurl、curl 脚本等），从任务中调用它们：

```lua
task("app-test")
    set_menu { usage = "xmake app-test", description = "运行 API 测试" }
    on_run(function ()
        os.exec("hurl --test tests/api/*.hurl")
    end)
task_end()
```

对于更简单的模式，保持 shell 脚本自包含（启动服务器、等待就绪、测试、
终止），然后直接调用它：

```lua
task("app-test")
    on_run(function ()
        os.exec("./scripts/run-api-tests.sh")
    end)
task_end()
```

## 子项目包含的注意事项

当使用 `includes("lunet")` 从源码构建时：

- **`os.scriptdir()` vs `os.projectdir()`**：Lunet 的 `xmake.lua` 对内部
  构建脚本使用 `os.scriptdir()`，以便在作为子项目包含时也能正确解析。
  你自己的 `xmake.lua` 也应使用 `os.scriptdir()`，原因相同。
- **构建目录**：子项目的输出落在*父*项目的 `build/` 目录中。无论你是
  父项目还是子项目，`lunet-run` 都在
  `build/<platform>/<arch>/release/lunet-run`。
- **配置标志**：Lunet 的 `xmake f` 选项（`--lunet_trace=n` 等）无论
  它是根项目还是子项目都同样有效。

## 参考实现

[lunet-realworld-example-app](https://github.com/lua-lunet/lunet-realworld-example-app)
是规范的下游消费者。其 `xmake.lua` 和 `scripts/` 目录是上述模式的可运行
参考。

## 不应做的事

- **不要**把 lunet 的 `xmake.lua` 任务（`xmake lint`、`xmake test` 等）
  复制到你自己的项目中。那些是测试 lunet 本身的。定义你自己的任务。
- **不要** fork lunet 的构建目标——使用 `includes("lunet")` 或消费
  发布压缩包。
- **不要**假设你的项目中存在 lunet 的 `test/` 目录——busted 规格是
  为 lunet 开发准备的，不是给下游应用的。
