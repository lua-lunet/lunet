# 将 Lunet 集成到您的项目中

本指南帮助您在自己的应用中构建和使用 Lunet。无需 xmake 使用经验。

## 什么是 xmake？

Lunet 使用 **xmake** 作为构建系统。xmake 是一个轻量级的跨平台构建工具（类似 CMake 或 Make）。您不需要深入学习 xmake——只需按照以下命令操作即可。

**安装 xmake：**

```bash
# Linux / macOS (curl)
curl -fsSL https://xmake.io/install.sh | bash

# 或通过包管理器
# macOS: brew install xmake
# Ubuntu: add-apt-repository ppa:xmake-io/xmake && apt install xmake
```

## 快速开始：构建 Lunet

### 1. 克隆并构建

```bash
git clone https://github.com/lua-lunet/lunet.git
cd lunet
xmake f -m release --lunet_trace=n --lunet_verbose_trace=n -y
xmake build
```

**这些命令的作用：**
- `xmake f` = 配置
- `-m release` = 优化构建（更快、更小的二进制文件）
- `--lunet_trace=n` = 不启用调试追踪（推荐用于生产环境）
- `-y` = 接受默认值，不提示

**输出文件：**
- `build/<platform>/<arch>/release/lunet.so` — Lua 模块
- `build/<platform>/<arch>/release/lunet-run` — 独立运行器

### 1b. 可选原生模块

Lunet 将可选原生模块作为独立的 xmake 目标提供。只构建你需要的部分。

示例：

```bash
# 数据库驱动
xmake build lunet-sqlite3
xmake build lunet-mysql
xmake build lunet-postgres

# 出站 HTTPS 客户端（libcurl）
xmake build lunet-httpc
```

### 2. 使用 lunet-run 运行应用

```bash
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" path/to/your_app.lua
```

### 2b. 可选：将 Lua 脚本嵌入 lunet-run

对于不希望 Lua 源码存放在磁盘上的部署场景，可以在发布构建中启用脚本嵌入：

```bash
xmake f -c -m release --lunet_embed_scripts=y --lunet_embed_scripts_dir=lua -y
xmake build lunet-bin
```

启用后，`lunet-run` 会在启动时将嵌入的脚本目录树提取到私有临时目录，并将该位置添加到 `package.path` 和 `package.cpath` 的前面。临时目录会在退出时删除。

注意：入口脚本参数必须是嵌入目录树内的安全相对路径（例如 `main.lua`）。绝对路径、包含 `..` 的路径以及 blob 之外的脚本都会被拒绝 —— 嵌入构建不再回退到从磁盘运行文件。

对于需要自定义原生 `main()` 并嵌入 Lua 应用的发布版使用者，请阅读
[EMBEDDING-CN.md](EMBEDDING-CN.md)，而不是将 Lunet 作为 xmake 子项目重新构建。

### 3. 或从普通 LuaJIT 加载 lunet.so

如果您更喜欢直接使用 `luajit`：

```bash
export LUA_CPATH="$(pwd)/build/$(xmake l print(os.host()))/$(xmake l print(os.arch()))/release/?.so;;"
luajit -e 'local lunet=require("lunet"); print(type(lunet))'
```

### 4. 将 Lunet 作为 xmake 子项目使用

如果您的应用有自己的 `xmake.lua`，可以把 Lunet 作为子项目引入，并通过
`add_deps("lunet")` 链接：

```lua
set_project("myapp")
set_languages("c99")
add_rules("mode.debug", "mode.release")

includes("lunet")

add_requires("pkgconfig::luajit", "pkgconfig::libuv")

target("myapp")
    set_kind("binary")
    add_files("src/*.c")
    add_deps("lunet")
    add_packages("luajit", "libuv")
target_end()
```

Lunet 会继续输出用于 Lua `require` 的 `lunet.so`，并额外生成兼容链接用的
`liblunet.so`（适配通过 `-l<name>` 进行依赖链接的工具链）。

---

## 构建配置（各场景使用指南）

| 配置 | 使用场景 | 命令 |
|------|----------|------|
| **发布版** | 生产环境，最佳性能 | `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y` |
| **调试 + 追踪** | 开发环境，捕获 bug | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y` |
| **详细追踪** | 详细调试，记录每个事件 | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y -y` |
| **ASan + EasyMem** | 内存 bug（ASan + 分配器完整性诊断） | `xmake f -c -m debug --lunet_trace=y --asan=y -y` |

**提示：** 切换配置时使用 `-c` 强制重新配置。

---

## 为您的项目设置 CI

如果您的应用使用 Lunet 并运行 CI（如 GitHub Actions），请使用以下配置测试：

1. **发布版** — `--lunet_trace=n --lunet_verbose_trace=n`
2. **调试追踪** — `--lunet_trace=y --lunet_verbose_trace=n`
3. **详细追踪** — `--lunet_trace=y --lunet_verbose_trace=y`
4. **ASan + EasyMem** — `--asan=y --lunet_trace=y`

这可以尽早捕获大多数生命周期和协程问题。

---

## 运行测试（`xmake test`）

```bash
xmake test
```

该命令按顺序执行三个步骤：

1. **`xmake check-types`** — 使用 lua-language-server 校验 `types/` 中的 LuaCATS 注解。类型错误会在任何测试执行前中止运行。
2. **`xmake build lunet-httpc`** — 构建出站 HTTP 客户端 C 模块，确保 `spec/httpc_spec.lua` 始终运行；无法构建该模块的平台会在此失败，而不是跳过。
3. **`busted spec/`** — Lua 测试套件：`spec/httpc_spec.lua`（针对 `lunet.httpc` C 模块的测试）和 `spec/lint_spec.lua`（运行 `luajit bin/lint_c_safety.lua`）。

输出会被 tee 到 `.tmp/logs/<时间戳>/busted.txt`。

### busted 运行在 LuaJIT 下（仅限 5.1 ABI）

lunet 的 C 模块链接 `libluajit-5.1`，因此把它们加载进 PUC Lua 进程会让两个互不兼容的 Lua 运行时共处同一地址空间：在 Linux 上会段错误，在 macOS 上会挂起。`PATH` 中的 `busted` 包装脚本无法避免这一点 —— luarocks 会把安装时探测到的解释器写死进包装脚本（在 Debian/Ubuntu 上即使用 `--lua-dir` 指向 LuaJIT，生成的仍是 `exec /usr/bin/lua5.1 … bin/busted`；Homebrew 上则是 `lua5.5`）。

因此 `xmake test` 忽略该包装脚本，自行启动 busted 的 Lua 入口：

```
luajit bin/busted_runner.lua spec/
```

`LUA_PATH` / `LUA_CPATH` 由 `luarocks --lua-version=5.1 path` 生成，因此无论解释器自身的默认搜索路径如何，都能在 5.1 的用户树与系统树中找到 busted。可用覆盖项：`$LUNET_LUAJIT`（解释器）与 `$LUNET_BUSTED`（busted 的 Lua 入口脚本路径）。

### pending 测试会导致失败

任何处于 busted `pending` 状态的测试都会导致整个运行失败：

```
error: busted reported N pending test(s) -- pending tests are forbidden ...
```

仅限本地迭代时，可设置 `LUNET_ALLOW_PENDING=1` 绕过该防护 —— 切勿在 CI 中设置。（该防护通过解析捕获的 busted 输出工作，因此仅适用于 Unix 路径。）

### 独立运行类型检查

```bash
xmake check-types
```

使用项目 `.luarc.json` 对 `types/` 运行 `lua-language-server --check`，并解析 JSON 报告作为门禁（LuaLS 3.15+ 即使报告诊断信息也会以 0 退出）。其元数据缓存（`--metapath`）指向 `.tmp/logs/` 下每次运行独立可写的目录；否则 LuaLS 会写入自身的安装目录，而该目录在 CI 中归 root 所有，会静默丢失所有内置类型（产生数百个虚假的 `undefined-doc-name` 错误）。

### CI

`.github/workflows/build.yml` 中的 `ubuntu-latest` 构建任务通过 `make test` 运行测试套件（Makefile 的 `test` 目标委托给 `xmake test`）。

---

## 本地预检安全门（推送前运行）

使用内置的 EasyMem 预检任务在本地运行与 CI 的 EasyMem+ASan 配置相同的快速泄漏/冒烟检查：

```bash
xmake preflight-easy-memory
```

它的作用：
- 配置 `debug + trace + ASan + EasyMem`
- 构建 `lunet-bin` 和数据库模块（如果本地缺少依赖，MySQL/Postgres 为可选）
- 运行 `test/ci_easy_memory_db_stress.lua`
- 运行 `test/ci_easy_memory_lsan_regression.lua`
- 将所有步骤日志写入 `.tmp/logs/YYYYMMDD_HHMMSS/easy_memory_preflight/`

---

## EasyMem 可选启用模式

Lunet 支持 [EasyMem/easy_memory](https://github.com/EasyMem/easy_memory) 作为分配器后端。

### 自动启用

当以下任一选项启用时，EasyMem 自动启用：
- `--lunet_trace=y`
- `--asan=y`

### 手动选择启用

在不启用追踪的开发档位下显式启用 EasyMem：

```bash
xmake f -c -m debug --lunet_trace=n --lunet_verbose_trace=n --easy_memory=y -y
xmake build
```

发布档位应默认保持 EasyMem 被剥离。

### 内存区大小调整

调整 EasyMem 内存区容量（MB）：

```bash
xmake f --easy_memory_arena_mb=256 -y
```

默认为 `128` MB（最小值限制为 `8` MB）。

---

## 可选：LuaJIT + Lunet ASan（仅 macOS）

如需深度内存调试（LuaJIT + Lunet 同时检测），使用仅限 macOS 的辅助工具：

```bash
xmake luajit-asan
xmake build-debug-asan-luajit
xmake repro-50-asan-luajit
```

这些辅助工具配置了 `--asan=y --lunet_trace=y`，因此 EasyMem 也会自动启用。

LuaJIT 版本锁定在 `xmake.lua` 中。如需覆盖：

```bash
xmake f --luajit_snapshot=2.1.0+openresty20250117 --luajit_debian_version=2.1.0+openresty20250117-2 -y
```

---

## 故障排除

| 问题 | 解决方案 |
|------|----------|
| `xmake: command not found` | 安装 xmake（参见上方"什么是 xmake？"） |
| `libuv not found` | 安装：`apt install libuv1-dev`（Linux），`brew install libuv`（macOS） |
| `luajit not found` | 安装：`apt install libluajit-5.1-dev`（Linux），`brew install luajit`（macOS） |
| 更改选项后构建失败 | 运行 `xmake f -c -y` 然后重新配置 |
| 架构错误 | 使用 `xmake f -a arm64`（或 `x64`）指定目标架构 |
| `--asan=y` 在特定 Windows 工具链上失败 | 确保您的 MSVC/clang-cl 版本支持 `/fsanitize=address` |

---

## 性能说明

调试追踪在典型工作负载中增加约 **7-8%** 的开销。生产环境请使用发布构建（`--lunet_trace=n`）。
