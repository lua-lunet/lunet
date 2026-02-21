# GraphLite 可选模块（`opt/graphlite`）

[English Documentation](GRAPHLITE.md)

本文档说明 Lunet 的 **可选** GraphLite 集成：

- Lua 模块：`require("lunet.graphlite")`
- 构建目标：`lunet-graphlite`
- xmake 任务：
  - `xmake opt-graphlite`
  - `xmake opt-graphlite-example`

## 为什么放在 `opt/` 而不是 `ext/`

GraphLite 当前没有像 `ext/` 所依赖库那样的稳定跨平台系统包/发布产物。
因此它不是通过系统库链接，而是按固定提交从源码拉取并构建。

所以该模块会在 CI 中验证，但**不会**打入 Lunet 官方发布二进制归档。

## 固定上游输入

- GraphLite 仓库：`https://github.com/GraphLite-AI/GraphLite.git`
- 固定提交：`a370a1c909642688130eccfd57c74b6508dcaea5`
- 固定 Rust 工具链：`1.87.0`

以上常量定义在 `xmake.lua` 中。

## 构建流程

### 1）构建可选 GraphLite 栈

```bash
xmake opt-graphlite
```

该任务会：

1. 先执行 `xmake build-release`
2. 将 GraphLite 按固定提交拉取到 `.tmp/opt/graphlite/GraphLite`
3. 安装固定 Rust 工具链
4. 构建 `graphlite-ffi` 共享库（`cargo +1.87.0 build --release -p graphlite-ffi`）
5. 将产物整理到：
   - `.tmp/opt/graphlite/install/lib/`
   - `.tmp/opt/graphlite/install/include/`
6. 构建 `lunet-graphlite`

### 2）运行可选冒烟/示例

```bash
xmake opt-graphlite-example
```

该任务会运行 `test/opt_graphlite_example.lua`，并自动设置：

- `LUA_CPATH`（追加 `build/**/release/opt/?.so` 或 `?.dll`）
- `LUNET_GRAPHLITE_LIB`（指向已整理的 GraphLite FFI 共享库）

## 运行时 API

`lunet.graphlite` 复用 Lunet 数据库驱动惯例：

- `db.open(path_or_config)`
- `db.close(conn)`
- `db.query(conn, gql)`
- `db.exec(conn, gql)`
- `db.escape(str)`

说明：

- `db.query_params` / `db.exec_params` 目前会拒绝位置参数（GraphLite 暂未支持该适配层）。
- 模块在运行时动态加载 GraphLite FFI（不依赖系统安装的 GraphLite）。
- 查询通过 libuv 线程池执行，连接句柄使用互斥锁保护。

## 路径与 Git 清洁

所有 GraphLite 源码/构建输出都位于 `.tmp/`（已被 git 忽略）：

- `.tmp/opt/graphlite/GraphLite`（上游源码）
- `.tmp/opt/graphlite/install`（整理后的共享库与头文件）
