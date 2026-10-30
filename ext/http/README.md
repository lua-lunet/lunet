# `lunet.http` — HTTP/1.1 framing, context and router

Pure-Lua HTTP/1.1 trio built on `lunet.socket`. See
[docs/HTTP.md](../../docs/HTTP.md) for the full reference.

## Verifying the framing

The HTTP/1.1 implementation is checked against the Http11Probe rig:

```sh
docker build -f ext/http/Dockerfile.http -t lunet-http-probe .
docker run --rm -v "$(pwd)/ext/http/spec:/out" lunet-http-probe
```

Do not change `ext/http/http.lua` without re-running this rig first. The
rig pins `probe-manifest.lua` / `probe-results.json` / `probe_allowlist.lua`,
which `spec/http_probe_spec.lua` asserts.

## Suggested deployment

Run behind nginx and raise the file-descriptor limit before exec:

`start.sh`:
```sh
#!/bin/sh
ulimit -n 65536
exec ./.lunet/lunet-run server.lua
```

nginx (excerpt):
```nginx
worker_connections 65536;
keepalive_timeout 65;
keepalive_requests 1000;
proxy_http_version 1.1;
proxy_set_header Connection "";
```

## Routing in ~165 lines

`ext/http/router.lua` is sub-200 lines: method+path dispatch with `:params`
and a middleware chain. Routes are a barrel of logic files.

`app/routes.lua` (realworld-lua, tag `v0.15.1-rw`):
```lua
require("auth_routes")
require("article_routes")
require("profile_routes")
```

`app/profile_routes.lua` (elided — imports and internals cut; middle banner
marks where validations/DB calls sit):
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

Server wiring (barrel + router):
```lua
require("app.routes")
-- in the connection loop:
router.handle(ctx)
```

Full reference: https://github.com/lua-lunet/realworld-lua (tag `v0.15.1-rw`),
starting at https://github.com/lua-lunet/realworld-lua/blob/main/app/routes.lua
