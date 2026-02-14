# 开发者工作流

[English Documentation](WORKFLOW.md)

本文档描述 Lunet 的标准开发者工作流，并列出所有可用的 xmake 任务。

## 标准构建系统：xmake

**xmake 是 Lunet 唯一的标准构建系统。** 没有 Makefile。

此决定在 PR #62（代码检查流水线改进）建立 xmake lint 任务和 CI 门控之后做出。所有开发者工作流、CI 流水线和文档均使用 xmake 命令。

### 为什么选择 xmake？

- **跨平台**：一个构建定义支持 Linux、macOS 和 Windows
- **依赖检测**：自动 pkg-config / vcpkg 包解析
- **任务系统**：自定义开发者任务（`xmake lint`、`xmake ci` 等）与构建目标共存于 `xmake.lua`
- **CI 一致性**：本地和 GitHub Actions 中运行相同的命令

## 任务目录

以下所有任务定义在 `xmake.lua` 中，可通过 `xmake <任务名>` 运行。

### 环境搭建

| 任务 | 描述 |
|------|------|
| `xmake init` | 通过 luarocks 安装本地 Lua QA 依赖（luafilesystem、busted、luacheck） |

### 质量门控

| 任务 | 描述 |
|------|------|
| `xmake lint` | 运行 C 安全代码检查（`bin/lint_c_safety.lua`） |
| `xmake check` | 对 `test/` 和 `spec/` 运行 luacheck 静态分析 |
| `xmake test` | 使用 busted 运行 Lua 单元测试（`spec/`） |

### 构建配置档位

| 任务 | 描述 |
|------|------|
| `xmake build-release` | 配置并构建优化的发布档位 |
| `xmake build-debug` | 配置并构建启用 `LUNET_TRACE` 的调试档位 |
| `xmake build-easy-memory-experimental` | 配置并构建 EasyMem 实验性发布档位 |

### 功能测试

| 任务 | 描述 |
|------|------|
| `xmake examples-compile` | 运行示例编译/语法检查（`test/ci_examples_compile.lua`） |
| `xmake sqlite3-smoke` | 构建并运行 SQLite3 示例冒烟测试（`examples/03_db_sqlite3.lua`） |
| `xmake smoke` | 运行所有数据库冒烟测试（SQLite3 + MySQL + Postgres，如可用） |
| `xmake stress` | 使用调试追踪档位运行并发压力测试 |
| `xmake socket-gc` | 运行套接字监听器 GC 回归测试 |

### CI / 发布

| 任务 | 描述 |
|------|------|
| `xmake ci` | 运行完整的本地 CI 一致性序列：lint、build-release、构建 lunet-sqlite3、示例编译检查、SQLite3 冒烟 |
| `xmake preflight-easy-memory` | 运行 EasyMem + ASan 预检冒烟，输出日志（`.tmp/logs/`） |
| `xmake release` | 完整发布门控：lint + test + stress + EasyMem 预检 + build-release |

### 高级 / 平台特定

| 任务 | 描述 |
|------|------|
| `xmake luajit-asan` | 在 `.tmp` 中构建 macOS LuaJIT ASan（仅 macOS） |
| `xmake build-debug-asan-luajit` | 使用 ASan + 自定义 LuaJIT ASan 构建 lunet-bin（仅 macOS） |
| `xmake repro-50-asan-luajit` | 使用 LuaJIT + Lunet ASan 运行 issue #50 复现（仅 macOS） |

## 推荐工作流

### 日常开发

```bash
xmake build-debug     # 启用追踪构建
xmake lint            # 检查 C 命名规范
xmake test            # 运行单元测试
```

### 推送前

```bash
xmake ci              # 完整的本地 CI 一致性检查
```

或 `AGENTS.md` 中指定的最低门控：

```bash
xmake lint
xmake test
xmake preflight-easy-memory
xmake build-release
```

### 准备发布

```bash
xmake release         # lint + test + stress + 预检 + build-release
```

## CI 流水线

GitHub Actions 工作流（`.github/workflows/build.yml`）在每次推送到 `main` 和每个 pull request 时运行。它在 Linux、macOS 和 Windows 上构建，然后运行示例编译检查和 SQLite3 冒烟测试。

`xmake ci` 任务在本地镜像此流水线，让你在推送前发现问题。

## 迁移说明

- **无 Makefile**：Lunet 从未提供过 Makefile。所有工作流使用 xmake。
- **Pre-commit 钩子**：仓库包含一个 pre-commit 钩子，自动运行 `xmake lint`。通过 `bin/install-hooks.sh` 安装或将 `.githooks/pre-commit` 复制到 `.git/hooks/`。
- **废弃策略**：如果未来需要构建系统迁移，xmake 任务将在过渡期间作为兼容层保留。
