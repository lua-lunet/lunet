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

在 nginx 后面运行，并在 exec 之前提高文件描述符上限：

`start.sh`：
```sh
#!/bin/sh
ulimit -n 65536
exec ./.lunet/lunet-run server.lua
```

nginx（摘录）：
```nginx
worker_connections 65536;
keepalive_timeout 65;
keepalive_requests 1000;
proxy_http_version 1.1;
proxy_set_header Connection "";
```

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
