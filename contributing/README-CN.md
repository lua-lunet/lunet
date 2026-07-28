# Contributing — 开发者设置

本目录包含 Lunet 开发者的一次性设置脚本。构建系统本身位于 `xmake` ——
本目录只负责准备宿主环境（系统包 + 固定到 luajit 的 Lua QA 工具）。

## 快速开始

在仓库根目录运行：

```
make init
```

`make init` 根据 `uname -s` 分发：

| 操作系统 | 运行的脚本 |
|----------|------------|
| macOS (Darwin) | `contributing/macos/Makefile` → `contributing/deps/macos.sh` |
| Linux (Debian/Ubuntu) | `contributing/debian/Makefile` → `contributing/deps/debian.sh` |
| Windows | 打印 `pwsh contributing\windows\setup.ps1` |

每个 OS 脚本安装系统开发库（与 `.github/workflows/build.yml` 中的列表一致），
然后 exec `contributing/deps/qa-luarocks.sh`，把 Lua QA rocks
（`luafilesystem`、`busted`、`luacheck`）安装到 luajit 解释器下 —— 而不是系统 Lua。

## Make 与 xmake 的领域划分

- **`make init`** = 开发者设置。安装系统包 + Lua QA 工具。每台机器运行一次
  （或新增依赖时再运行）。
- **`xmake build-release`**、**`xmake test`**、**`xmake stress`** = 构建软件。
  每次改动都运行。

`xmake init` 仍作为仅安装 QA 工具的入口，在 Unix 上委托给同一个
`contributing/deps/qa-luarocks.sh` 脚本。

## 工具版本（mise）

仓库根目录的 `.mise.toml` 通过 `github:xmake-io/xmake` 后端固定了
**xmake** 的版本（当前为 `3.0.8`，xmake 不在 mise 的核心注册表中）。CI
在每个 `xmake-io/github-action-setup-xmake` 步骤中使用相同的固定版本。
如果你安装了 [mise](https://mise.jdx.dev/)，运行 `mise install` 会自动
拉取正确的 xmake；否则 PATH 上任何 xmake 3.0.8 都可以。

其他所有工具（luajit、luarocks、系统开发库）都来自 `contributing/deps/`
下的 OS 依赖脚本。mise 的 luajit 插件已损坏（`list-all` 失败，无法列出
版本），luarocks 也不是 mise 插件，xmake 本身也需要 `github:` 后端前缀，
因此系统路径仍然是 Lua 工具链的受支持配置方式。

## macOS：PKG_CONFIG_PATH

Homebrew 的 `zlib`、`curl`、`libpq`、`mysql-client` 是 keg-only。
`make init` 之后，macos 脚本会打印 `export PKG_CONFIG_PATH=...` 一行。
把它加到你的 shell profile —— 数据库驱动、httpc 和 `xmake preflight-easy-memory`
都需要它。

## CI 复用

同一套 `contributing/deps/*` 脚本将在后续工作中被 CI 调用（详见 issue #123）。
脚本是幂等的，可以安全重复运行。

## 故障排查

### Homebrew Lua 5.5 下 `luacheck` 无法运行

luacheck 1.2.0 无法在 Homebrew 默认的 `lua` 5.5 下运行。`qa-luarocks.sh`
会把安装固定到 luajit：

```
luarocks --lua-version=5.1 --lua-dir=$(brew --prefix luajit) install luacheck
```

如果 `luacheck --version` 失败，重新运行 `make init`（或 `xmake init`）
以重新安装到正确的解释器下。

### `luajit not found`

请先安装 luajit：

- macOS：`brew install luajit`
- Debian/Ubuntu：`sudo apt-get install luajit libluajit-5.1-dev`
