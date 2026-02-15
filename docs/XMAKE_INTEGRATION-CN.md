# 将 Lunet 集成到你的项目

本指南帮助你在自己的应用中构建和使用 Lunet。无需 xmake 经验。

## 什么是 xmake？

Lunet 使用 **xmake** 作为构建系统。xmake 是一个轻量级、跨平台的构建工具（类似 CMake 或 Make）。你无需深入学习 xmake——只需按照下面的命令操作。

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
- `-m release` = 优化构建（快速、体积小）
- `--lunet_trace=n` = 不启用调试追踪（生产环境推荐）
- `-y` = 接受默认值，不提示

**输出文件：**
- `build/<平台>/<架构>/release/lunet.so` — Lua 模块
- `build/<平台>/<架构>/release/lunet-run` — 独立运行器

### 2. 使用 lunet-run 运行你的应用

```bash
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" path/to/your_app.lua
```

### 2b. 可选：将 Lua 脚本嵌入 lunet-run

对于部署时不希望 Lua 源代码存在于磁盘的场景，可以在发布构建中启用脚本嵌入：

```bash
xmake f -c -m release --lunet_embed_scripts=y --lunet_embed_scripts_dir=lua -y
xmake build lunet-bin
```

启用后，`lunet-run` 在启动时会将嵌入的脚本树提取到私有临时目录，并将该位置添加到 `package.path` 和 `package.cpath` 的前面。

### 3. 或从纯 LuaJIT 加载 lunet.so

如果你更喜欢直接使用 `luajit`：

```bash
export LUA_CPATH="$(pwd)/build/$(xmake l print(os.host()))/$(xmake l print(os.arch()))/release/?.so;;"
luajit -e 'local lunet=require("lunet"); print(type(lunet))'
```

---

## 构建配置档位（何时使用）

| 档位 | 使用场景 | 命令 |
|------|---------|------|
| **Release** | 生产环境，最佳性能 | `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y` |
| **Debug + trace** | 开发环境，捕获 bug | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y` |
| **Verbose trace** | 详细调试，记录每个事件 | `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=y -y` |
| **ASan + EasyMem** | 内存错误（ASan + 分配器完整性诊断） | `xmake f -c -m debug --lunet_trace=y --asan=y -y` |
| **Experimental EasyMem Release** | 带分配器诊断的发布二进制 | `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory_experimental=y --easy_memory_arena_mb=128 -y` |

**提示：** 切换档位时使用 `-c` 强制清除重新配置。

---

## 你的项目的 CI 设置

如果你的应用使用 Lunet 并运行 CI（如 GitHub Actions），使用这些档位进行测试：

1. **Release** — `--lunet_trace=n --lunet_verbose_trace=n`
2. **Debug trace** — `--lunet_trace=y --lunet_verbose_trace=n`
3. **Verbose trace** — `--lunet_trace=y --lunet_verbose_trace=y`
4. **ASan + EasyMem** — `--asan=y --lunet_trace=y`

这可以尽早捕获大多数生命周期和协程问题。

---

## 本地预检安全门控（提交前运行）

使用内置的 EasyMem 预检任务在本地运行与 CI 使用的 EasyMem+ASan 档位相同的快速泄漏/冒烟检查：

```bash
xmake preflight-easy-memory
```

作用：
- 配置 `debug + trace + ASan + EasyMem`
- 构建 `lunet-bin` 和 DB 模块（MySQL/Postgres 如果本地缺少依赖则可选）
- 运行 `test/ci_easy_memory_db_stress.lua`
- 运行 `test/ci_easy_memory_lsan_regression.lua`
- 将所有步骤日志写入 `.tmp/logs/YYYYMMDD_HHMMSS/easy_memory_preflight/`

---

## EasyMem 选择加入模式

Lunet 支持 [EasyMem/easy_memory](https://github.com/EasyMem/easy_memory) 作为分配器后端。

### 自动启用

当启用以下任一选项时，EasyMem 会自动启用：
- `--lunet_trace=y`
- `--asan=y`

### 手动选择加入

不启用追踪时显式启用 EasyMem：

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory=y -y
xmake build
```

### 实验性发布模式

在发布模式中启用完整诊断以进行分配器分析：

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory_experimental=y --easy_memory_arena_mb=128 -y
xmake build
```

### Arena 大小调整

以 MB 为单位调整 EasyMem arena 容量：

```bash
xmake f --easy_memory_arena_mb=256 -y
```

默认为 `128` MB（最小限制为 `8` MB）。

---

## 可选：LuaJIT + Lunet ASan（macOS）

对于深度内存调试（LuaJIT + Lunet 都经过检测），使用 macOS 专用的辅助命令：

```bash
xmake luajit-asan
xmake build-debug-asan-luajit
xmake repro-50-asan-luajit
```

这些辅助命令配置 `--asan=y --lunet_trace=y`，因此 EasyMem 也会自动启用。

LuaJIT 版本固定在 `xmake.lua` 中。如需覆盖：

```bash
xmake f --luajit_snapshot=2.1.0+openresty20250117 --luajit_debian_version=2.1.0+openresty20250117-2 -y
```

---

## 将 Lunet 用作子项目

如果你正在使用 xmake 构建更大的应用，可以将 lunet 作为子项目包含，而不是单独构建它。这种方法允许你的项目自动管理 lunet 的构建配置和依赖项。

### 步骤 1：将 lunet 添加到你的项目

将 lunet 克隆或添加为项目中的子目录：

```bash
cd your-project/
git submodule add https://github.com/lua-lunet/lunet.git lunet
# 或简单地克隆它：
# git clone https://github.com/lua-lunet/lunet.git lunet
```

### 步骤 2：在你的 xmake.lua 中包含 lunet

在项目的 `xmake.lua` 中添加 lunet：

```lua
-- 将 lunet 作为子项目包含
includes("lunet")

-- 你的应用目标
target("myapp")
    set_kind("binary")
    add_files("src/*.c")
    
    -- 链接到 lunet
    add_deps("lunet")
    add_packages("luajit", "libuv")
    
    -- 可选：也链接数据库驱动
    -- add_deps("lunet-sqlite3")
    -- add_deps("lunet-mysql")
    -- add_deps("lunet-postgres")
target_end()
```

### 步骤 3：配置并构建

```bash
xmake f -m release -y
xmake build
```

你的应用将自动构建 lunet 并链接它。lunet 共享库将在你的构建输出目录中可用。

### 从父项目使用 lunet 目标

当 lunet 作为子项目包含时，你可以从父项目构建特定的 lunet 目标：

```bash
# 只构建核心 lunet 库
xmake build lunet

# 构建带数据库驱动的 lunet
xmake build lunet-sqlite3

# 构建你的应用（如果需要会自动构建 lunet）
xmake build myapp
```

### 示例：最小父项目结构

```
your-project/
├── lunet/              # Lunet 子项目（git submodule 或 clone）
│   ├── xmake.lua
│   ├── src/
│   └── include/
├── src/
│   └── main.c          # 你的应用代码
└── xmake.lua           # 你项目的 xmake.lua
```

**your-project/xmake.lua：**

```lua
set_project("myapp")
set_version("1.0.0")
set_languages("c99")

add_rules("mode.debug", "mode.release")

-- 包含 lunet
includes("lunet")

-- 包需求（与 lunet 共享）
if is_plat("windows") then
    add_requires("vcpkg::luajit", {alias = "luajit"})
    add_requires("vcpkg::libuv", {alias = "libuv"})
else
    add_requires("pkgconfig::luajit", {alias = "luajit"})
    add_requires("pkgconfig::libuv", {alias = "libuv"})
end

target("myapp")
    set_kind("binary")
    add_files("src/*.c")
    add_deps("lunet")
    add_packages("luajit", "libuv")
target_end()
```

### 注意：子项目路径解析

从此版本开始，lunet 的 `xmake.lua` 正确使用 `os.scriptdir()` 而不是 `os.projectdir()` 来定位内部构建脚本。这确保当作为子项目包含时，lunet 可以相对于自己的位置定位其 `bin/` 目录，而不是父项目的根目录。

---

## 故障排除

| 问题 | 解决方案 |
|------|---------|
| `xmake: command not found` | 安装 xmake（参见上面"什么是 xmake？"） |
| `libuv not found` | 安装：`apt install libuv1-dev`（Linux），`brew install libuv`（macOS） |
| `luajit not found` | 安装：`apt install libluajit-5.1-dev`（Linux），`brew install luajit`（macOS） |
| 更改选项后构建失败 | 运行 `xmake f -c -y` 然后重新配置 |
| 错误的架构 | 使用 `xmake f -a arm64`（或 `x64`）来指定特定架构 |
| 特定 Windows 工具链上 `--asan=y` 失败 | 确保你的 MSVC/clang-cl 版本支持 `/fsanitize=address` |

---

## 性能说明

调试追踪在典型工作负载中增加大约 **7–8%** 的开销。生产环境使用发布构建（`--lunet_trace=n`）。
