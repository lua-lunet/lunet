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

> **nginx here is for illustration.** We are simply naming a common one;
> OpenResty, Envoy, Caddy, Traefik, HAProxy, and many other excellent
> products exist. This is not a recommendation that nginx is the best edge
> proxy - it is one worked example of an edge that lets lunet stay off the
> network entirely. See
> [docs/SECURITY_ARCHITECTURE.md](../../docs/SECURITY_ARCHITECTURE.md) for
> the design discussion, and always read the latest documentation of
> whichever edge you deploy.

Run behind the edge and raise the file-descriptor limit before exec:

`start.sh`:
```sh
#!/bin/sh
ulimit -n 65536
exec ./.lunet/lunet-run server.lua
```

nginx (excerpt):
```nginx
# events {} context - fan-out:
worker_connections 65536;

# http {} / server {} context - caps and timeouts:
keepalive_timeout 65;
keepalive_requests 1000;            # nginx default since 1.19.10 - stated to pin it
large_client_header_buffers 4 8k;   # nginx default, stated explicitly: 32 KiB header
                                    # section = MAX_HEADER_BYTES default
client_max_body_size 1m;            # nginx default, stated explicitly: = MAX_BODY_BYTES
                                    # default; oversize answers 413 here
client_header_timeout 10s;          # an incomplete header answers 408 here (default 60s)
client_body_timeout 10s;            # a stalled body answers 408 here (default 60s)
ignore_invalid_headers off;         # malformed header names answer 400, not a silent drop
merge_slashes off;                  # //path is rejected, not normalized

# server {} -> location - the proxy to lunet over the Unix socket:
location / {
    proxy_pass http://unix:/run/lunet/lunet.sock;
    proxy_http_version 1.1;         # default 1.1 since 1.29.7; 1.0 before - stated to be version-proof
    proxy_request_buffering on;     # the default, stated on purpose: the entire request body is
                                    # read from the client before anything reaches lunet
    proxy_set_header Connection ""; # upstream keep-alive
}
```

## Caps and edge alignment

The parser caps ship as nginx's defaults, in `ext/http/http_caps.lua`:

| Cap | Default | nginx directive |
|-----|---------|-----------------|
| `MAX_REQUEST_LINE_BYTES` | 8 KiB | one `large_client_header_buffers` buffer |
| `MAX_HEADER_BYTES` | 32 KiB | `large_client_header_buffers 4 8k` |
| `MAX_BODY_BYTES` | 1 MiB | `client_max_body_size 1m` |

nginx was chosen as the baseline, not as a mandate. If you front lunet
with a different edge - Envoy, Traefik, HAProxy, Caddy, a cloud load
balancer or a WAF - check your chosen edge service's settings and align
lunet's caps to them: the edge must always answer first, so lunet is
never the strictest link in the chain and never the visible 431/413 for
a request the edge accepted.

Operators may need to raise the header cap for very large security
tokens in headers: a SPNEGO auth header can reach ~12K for a single
field, JWTs run 10-20K, and the edge injects its own headers
(`X-Forwarded-For` and friends) on top of whatever the client sent.

To override, edit `ext/http/http_caps.lua` (pure Lua, ships beside
`http.lua`, no rebuild needed) or set the build options:

```sh
xmake f --lunet_http_request_line_max=8192 --lunet_http_header_max=32768 --lunet_http_body_max=1048576
```

Unset options keep the file's defaults.

## Worked edge examples, tested

[ext/http/edge/](edge/README.md) carries the same application (the
realworld-lua demo at v0.18.1) behind four edges - nginx, OpenResty,
Traefik, Envoy - each built from one shared Debian base image and proven
by a conformance suite (happy paths, oversize body, oversize header
section, drip-feed). The key delta the examples make concrete: full-request
buffering is nginx's default (opt-out); Traefik and Envoy stream by
default and the buffering must be installed explicitly, or lunet's own
1 MiB 413 becomes the live cap.

| Edge | Buffering | Example |
|------|-----------|---------|
| nginx | default (opt-out) | [edge/Dockerfile.nginx](edge/Dockerfile.nginx) |
| OpenResty | default (opt-out) | [edge/Dockerfile.openresty](edge/Dockerfile.openresty) |
| Traefik | opt-in middleware | [edge/Dockerfile.traefik](edge/Dockerfile.traefik) |
| Envoy | opt-in filter | [edge/Dockerfile.envoy](edge/Dockerfile.envoy) |

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
