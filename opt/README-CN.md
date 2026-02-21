# 可选模块目录（`opt/`）

`opt/` 用于存放**可选、非一线发布**的 Lunet 模块：这些模块依赖的上游库在
Lunet 支持的平台上通常没有稳定的系统包分发，需要在本地/CI 从源码构建。

## `opt/` 与 `ext/` 的区别

- `ext/`：
  - 封装可通过平台包管理器稳定获取的成熟库（`apt`、Homebrew、vcpkg）
  - 面向常规发布产物打包
- `opt/`：
  - 封装需要源码拉取与自建的库
  - 仅通过显式 xmake 任务构建
  - 会在 CI 覆盖验证，但不作为官方 Lunet 发布二进制的一部分

## 当前可选模块

- `opt/graphlite` - GraphLite GQL 数据库集成（`require("lunet.graphlite")`）

## 构建流程

```bash
# 构建固定提交版本的 GraphLite FFI + Lunet graphlite 模块
xmake opt-graphlite

# 运行可选 GraphLite 示例/冒烟脚本
xmake opt-graphlite-example
```

GraphLite 源码与构建输出位于 `.tmp/opt/graphlite/`（已被 git 忽略）。
