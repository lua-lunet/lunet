# opt/ — 可选实验模块

`opt/` 目录包含的 lunet 模块所依赖的库**没有官方二进制发布**，不在 lunet
支持的平台（Linux Debian LTS/Trixie、macOS Homebrew、Windows vcpkg）上提供。

## `opt/` 与 `ext/` 的区别

| 方面 | `ext/` | `opt/` |
|------|--------|--------|
| **平台可用性** | 库可通过系统包管理器获取（`apt`、`brew`、`vcpkg`） | 库必须从源码构建/内嵌 |
| **CI 处理** | 在所有平台上构建和测试；包含在发布归档中 | 在 CI 中构建和测试，但**不**包含在发布归档中 |
| **xmake 默认行为** | 非默认（但可简单执行 `xmake build lunet-<name>`） | 非默认；每个模块有自己的 `xmake opt-<name>` 目标 |
| **二进制发布** | 包含在 `lunet-{linux,macos,windows}` 归档中 | 不发布 — 用户需从源码构建 |
| **稳定性** | 封装成熟的 LTS 发布库 | 封装预发布或小众库 |

## 当前模块

### GraphLite (`opt/graphlite/`)

基于 [GraphLite](https://github.com/GraphLite-AI/GraphLite) 的 ISO GQL
（图查询语言）图数据库。GraphLite 是一个用 Rust 编写的可嵌入图数据库，
实现了 ISO GQL 标准。

由于 GraphLite 没有官方平台包，我们：

1. 在固定提交处克隆 GraphLite 仓库
2. 使用固定的 Rust LTS 工具链构建 `graphlite-ffi` crate
3. 生成 `libgraphlite_ffi.so` / `.dylib` / `.dll`
4. 我们的 C99 shim（`opt/graphlite/graphlite.c`）在运行时通过
   `dlopen`/`LoadLibrary` 动态加载该库
5. Lua 模块（`require("lunet.graphlite")`）提供与 SQLite3 驱动相同的
   协程 yield/resume 语义

**构建：**
```bash
xmake opt-graphlite          # 获取、构建 Rust FFI 库、编译 C shim
xmake opt-graphlite-example  # 运行示例脚本
```

## 添加新模块

添加新的 `opt/` 模块时：

1. 创建 `opt/<name>/` 包含 C shim 和头文件
2. 添加 xmake 目标 `opt-<name>` 和 `opt-<name>-example`
3. 在 `xmake.lua` 中固定上游提交哈希
4. 确保 `.gitignore` 覆盖所有内嵌构建产物
5. 添加 CI 步骤进行构建但**不**打包发布
6. 应用与核心模块相同的 `lunet_mem.h`、`trace.h` 和 ASAN 支持
