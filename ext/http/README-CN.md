# `lunet.http` — HTTP/1.1 解析、上下文与路由

构建于 `lunet.socket` 之上的纯 Lua HTTP/1.1 三件套。完整参考见
[docs/HTTP-CN.md](../../docs/HTTP-CN.md)。

## 帧格式验证

HTTP/1.1 实现通过 Http11Probe 装置验证：

```sh
docker build -f ext/http/Dockerfile.http -t lunet-http-probe .
docker run --rm -v "$(pwd)/ext/http/spec:/out" lunet-http-probe
```

在重新运行该装置之前，不要修改 `ext/http/http.lua`。该装置会固化
`probe-manifest.lua` / `probe-results.json` / `probe_allowlist.lua`，
`spec/http_probe_spec.lua` 对它们做断言。

## 推荐部署方式

> **这里的 nginx 仅为说明之用。** 我们只是举一个常见的产品；OpenResty、
> Envoy、Caddy、Traefik、HAProxy 以及许多其他优秀产品同样存在。这不是在
> 推荐 nginx 是最好的边缘代理 - 它只是一个可落地的示例：一个让 lunet 完全
> 远离网络的边缘。设计讨论见
> [docs/SECURITY_ARCHITECTURE-CN.md](../../docs/SECURITY_ARCHITECTURE-CN.md)，
> 并请始终阅读你所部署边缘的最新文档。

在边缘代理后面运行，并在 exec 之前提高文件描述符上限：

`start.sh`：
```sh
#!/bin/sh
ulimit -n 65536
exec ./.lunet/lunet-run server.lua
```

nginx（摘录）：
```nginx
# events {} 上下文 - 扇出：
worker_connections 65536;

# http {} / server {} 上下文 - 上限与超时：
keepalive_timeout 65;
keepalive_requests 1000;            # nginx 默认（自 1.19.10 起）- 写明以固化
large_client_header_buffers 4 8k;   # nginx 默认值，有意写明：32 KiB 头部总量
                                    # = MAX_HEADER_BYTES 默认值
client_max_body_size 1m;            # nginx 默认值，有意写明：= MAX_BODY_BYTES
                                    # 默认值；超限在边缘答 413
client_header_timeout 10s;          # 未传完的请求头在此答 408（默认 60s）
client_body_timeout 10s;            # 停滞的请求体在此答 408（默认 60s）
ignore_invalid_headers off;         # 畸形头名答 400，而非静默丢弃
merge_slashes off;                  # //path 被拒绝，而非归一化

# server {} -> location - 经 Unix 套接字代理到 lunet：
location / {
    proxy_pass http://unix:/run/lunet/lunet.sock;
    proxy_http_version 1.1;         # 自 1.29.7 起默认 1.1；此前为 1.0 - 写明以免版本歧义
    proxy_request_buffering on;     # 默认值，有意写明：在到达 lunet 之前，先从客户端
                                    # 读入完整的请求体
    proxy_set_header Connection ""; # 上游 keep-alive
}
```

## 上限与边缘对齐

解析器上限默认取 nginx 的默认值，位于 `ext/http/http_caps.lua`：

| 上限 | 默认值 | nginx 指令 |
|------|--------|------------|
| `MAX_REQUEST_LINE_BYTES` | 8 KiB | 单个 `large_client_header_buffers` 缓冲区 |
| `MAX_HEADER_BYTES` | 32 KiB | `large_client_header_buffers 4 8k` |
| `MAX_BODY_BYTES` | 1 MiB | `client_max_body_size 1m` |

选 nginx 作为基线，并非强制。若前置其他边缘（Envoy、Traefik、HAProxy、
Caddy、云负载均衡器或 WAF），请查看你所选边缘服务的设置，并将 lunet 的
上限对齐到它：边缘必须始终先应答，lunet 永远不是链上最严的一环，也不会
对边缘已接受的请求答出可见的 431/413。

若请求头中携带很大的安全令牌，运维可能需要上调请求头上限：SPNEGO 认证头
单字段可达约 12K，JWT 为 10-20K，边缘还会在客户端请求头之上注入自己的头
（`X-Forwarded-For` 等）。

覆盖方式：直接编辑 `ext/http/http_caps.lua`（纯 Lua，与 `http.lua` 一同
发布，无需重新构建），或在构建时设置选项：

```sh
xmake f --lunet_http_request_line_max=8192 --lunet_http_header_max=32768 --lunet_http_body_max=1048576
```

未设置的选项保持文件中的默认值。

## 已测试的边缘示例

[ext/http/edge/](edge/README-CN.md) 将同一应用（realworld-lua 演示 v0.18.1）
放到四种边缘之后 - nginx、OpenResty、Traefik、Envoy - 每种都构建自同一个
Debian 基础镜像，并由一致性套件验证（正常路径、超大请求体、超大头部区块、
滴灌）。这些示例所要呈现的关键差异：整请求缓冲是 nginx 的默认行为（可显式
关闭）；Traefik 与 Envoy 默认流式转发，必须显式安装缓冲，否则 lunet 自己的
1 MiB 413 就成了实际生效的上限。

| 边缘 | 缓冲 | 示例 |
|------|------|------|
| nginx | 默认（可显式关闭） | [edge/Dockerfile.nginx](edge/Dockerfile.nginx) |
| OpenResty | 默认（可显式关闭） | [edge/Dockerfile.openresty](edge/Dockerfile.openresty) |
| Traefik | 需显式开启的中间件 | [edge/Dockerfile.traefik](edge/Dockerfile.traefik) |
| Envoy | 需显式开启的过滤器 | [edge/Dockerfile.envoy](edge/Dockerfile.envoy) |

## 路由：约 165 行

`ext/http/router.lua` 不到 200 行：带 `:params` 的方法+路径分发，加上中间件链。
路由是一组逻辑文件的桶式注册。

`app/routes.lua`（realworld-lua，tag `v0.15.1-rw`）：
```lua
require("auth_routes")
require("article_routes")
require("profile_routes")
```

`app/profile_routes.lua`（已删节——导入与内部细节已裁剪；中间的横幅标记
验证/数据库调用所在的位置）：
```lua
local router = require("lunet.http_router")
local json = require("lunet.jsonic")
-- ... imports ...

local function format_profile(env_config, profile, current_user_id)
    -- ... format ...
end

router.route("GET", "/api/profiles/:username", function(env_config, ctx, params)
    -- ... get current user ...
    -- ... fetch profile ...
    return json_response(200, { profile = format_profile(env_config, profile, current_user_id) })
end)

router.route("POST", "/api/profiles/:username/follow", function(env_config, ctx, params)
    -- ... auth ...
    -- ... fetch profile ...
    -- perform validations
    return json_response(200, { profile = format_profile(env_config, profile, user.id) })
end)

router.route("DELETE", "/api/profiles/:username/follow", function(env_config, ctx, params)
    -- ... auth ...
    -- ... fetch profile ...
    -- perform validations
    return json_response(200, { profile = format_profile(env_config, profile, user.id) })
end)
```

服务器接线（桶式注册 + 路由器）：
```lua
require("app.routes")
-- 在连接循环中：
router.handle(ctx)
```

完整参考：https://github.com/lua-lunet/realworld-lua（tag `v0.15.1-rw`），
起点：https://github.com/lua-lunet/realworld-lua/blob/main/app/routes.lua
