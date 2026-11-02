# 边缘示例：一个应用，四种边缘

这些是同一应用前接不同边缘服务的**示例** - 用来说明设置的示意，不是推荐。部署任何边缘之前，请始终阅读其所对应产品的最新文档。

每个变体中的应用完全相同：[realworld-lua](https://github.com/lua-lunet/realworld-lua) 演示应用 v0.18.1（与 lunet v0.18.1 匹配），运行在共享的 Debian trixie 基础镜像上。每个变体都以该基础镜像为 `FROM`，在同一个应用之上换用不同的边缘服务器：

| 边缘 | Dockerfile | 整请求体缓冲 | 无配置时的请求体上限 |
|---|---|---|---|
| [nginx](Dockerfile.nginx) | 基础镜像自带的参考边缘 | **默认**（可显式关闭） | 1 MiB |
| [OpenResty](Dockerfile.openresty) | 同 nginx 血统 + 边缘 Lua 脚本 | **默认**（可显式关闭） | 1 MiB |
| [Traefik](Dockerfile.traefik) | 按路由挂载 buffering 中间件 | 需显式开启 | 无 |
| [Envoy](Dockerfile.envoy) | 过滤链中加入 buffer 过滤器 | 需显式开启 | 无 |

中间那一列就是这些示例的意义所在。nginx（以及捆绑 nginx 的 OpenResty）默认在转发之前缓冲完整的请求体。Traefik 和 Envoy **默认流式转发**：如果没有 buffering 中间件（Traefik）或 buffer 过滤器（Envoy），任意大小的请求体都会直接流过，lunet 自己的 1 MiB 413 就成了实际生效的上限，而不是边缘先应答。示例配置把这些行为显式安装好，因此四种边缘都会对超过 1 MiB 的请求应答 `413`，并在 lunet 看到之前拒绝超大的头部区块。

## 布局

- `Dockerfile.base` - 共享基础镜像：Debian trixie、realworld 应用（由其自身的发布脚本摘要校验获取）、lunet v0.18.1 运行时，以及预配置为参考边缘的 nginx（`conf/nginx-edge.conf`）。按本机构建（Apple Silicon colima 上为 arm64，其余为 amd64）。
- `Dockerfile.nginx` / `Dockerfile.openresty` / `Dockerfile.traefik` / `Dockerfile.envoy` - 每种边缘一个，均 `FROM lunet-edge-base`，各自加入自己的边缘服务器与配置。OpenResty 是唯一的例外：其 apt 仓库只发布 amd64 包，因此该变体固定为 linux/amd64（驱动会先构建 amd64 基础镜像；在 Apple Silicon 上以仿真运行 - 与 realworld-lua 项目自身 Dockerfile 的选择相同）。
- `conf/` - 每种边缘一份配置，都携带同一契约：开启请求缓冲（在默认不缓冲的产品上）、1 MiB 请求体上限、32 KiB 头部区块上限、10 秒读超时。
- `conformance.lua` - 一致性套件（见下）。
- `run-conformance.sh` - 驱动脚本：先构建基础镜像，然后对每种边缘构建变体，在同一 docker 网络上运行 PostgreSQL 与该变体，并对其执行套件。

## 一致性套件

`conformance.lua` **运行在 lunet 运行时上**（在与边缘同一 docker 网络的容器内），从外部驱动边缘。它对每种边缘断言同一契约：

1. **正常路径** - 应用的 `/health` 与 RealWorld API 端点（注册、认证、创建与列出文章）经边缘应答不变。
2. **超大请求体** - 超过 1 MiB 上限的 2 MiB 请求体由边缘应答 `413`，绝不转发。
3. **超大头部区块** - 超过 32 KiB 上限的 40 KiB 头部区块由边缘拒绝（nginx 与 OpenResty 上为 `400`/`414`，Traefik 与 Envoy 上为 `431`）。
4. **滴灌** - 每秒一个分片滴灌的请求会被边缘的 10 秒读超时切断；边缘绝不完成该请求。

运行全部四种（在仓库根目录；需要 docker）：

```sh
ext/http/edge/run-conformance.sh
```

或逐个运行：

```sh
ext/http/edge/run-conformance.sh envoy
```

## 说明

- 容器内的应用监听**环回 TCP**（其固定的 `server.lua` 只接受主机/端口）；边缘是唯一具有对外监听的进程。裸机部署时，同一形态是边缘与应用之间的 Unix 套接字 - 见安全架构文档。
- nginx 变体的 Dockerfile 除了选择边缘类型外什么都不做：基础镜像恰好已为其配置好。这是有意的 - 它是其余三者所对照的参考边缘。
- 边缘设置与 [ext/http README](../README-CN.md) 中的已注释设置块一致；设计讨论位于[安全架构文档](../../../docs/SECURITY_ARCHITECTURE-CN.md)。
