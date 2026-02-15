# 下游项目徽章指南

如果您的项目使用 Lunet，可以在 README 中添加徽章来展示构建状态、Lunet 版本等信息。本指南提供开箱即用的 Markdown 代码片段。

## Lunet 版本徽章

展示您的项目依赖的 Lunet 版本：

```markdown
[![Lunet](https://img.shields.io/badge/Lunet-v0.2.1-blue?logo=lua)](https://github.com/lua-lunet/lunet)
```

将 `v0.2.1` 替换为您实际使用的 Lunet 版本。最新版本请查看 [lunet 发布页](https://github.com/lua-lunet/lunet/releases)。

## 构建状态徽章

如果您的项目有使用 Lunet 构建或测试的 GitHub Actions：

```markdown
[![Build](https://github.com/YOUR_ORG/YOUR_REPO/actions/workflows/build.yml/badge.svg)](https://github.com/YOUR_ORG/YOUR_REPO/actions/workflows/build.yml)
```

将 `YOUR_ORG` 和 `YOUR_REPO` 替换为您的仓库路径。如果工作流文件名不同（如 `ci.yml`、`test.yml`），请相应调整。

## 许可证徽章

```markdown
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
```

## 组合示例

基于 Lunet 项目的典型 README 头部：

```markdown
# 我的 Lunet 应用

[![Build](https://github.com/lua-lunet/my-app/actions/workflows/build.yml/badge.svg)](https://github.com/lua-lunet/my-app/actions/workflows/build.yml)
[![Lunet](https://img.shields.io/badge/Lunet-v0.2.1-blue?logo=lua)](https://github.com/lua-lunet/lunet)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

基于 [Lunet](https://github.com/lua-lunet/lunet) 构建的高性能应用。
```

## 自定义

- **Shields.io** 支持多种样式：`?style=flat`、`?style=flat-square`、`?style=for-the-badge`
- **颜色**：附加 `?color=green` 或使用语义颜色如 `success`、`important`、`informational`
- **图标**：添加 `?logo=github` 或 `?logo=lua` 以覆盖图标

使用 flat-square 样式的示例：

```markdown
[![Lunet](https://img.shields.io/badge/Lunet-v0.2.1-blue?style=flat-square&logo=lua)](https://github.com/lua-lunet/lunet)
```

## 链接到 Lunet

请始终将徽章链接到 Lunet 仓库，以便用户发现该库：

```markdown
[![Lunet](https://img.shields.io/badge/Lunet-v0.2.1-blue)](https://github.com/lua-lunet/lunet)
```
