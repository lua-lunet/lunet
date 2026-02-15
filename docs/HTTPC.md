# lunet.httpc (Outbound HTTPS Client)

`lunet.httpc` is an **optional**, **client-only** HTTPS module for Lunet built on **libcurl**.

Design goals:
- Outbound HTTPS requests from Lunet without spawning external processes (no `curl` subprocess).
- Coroutine-friendly API: `request()` **yields** and resumes the calling coroutine.
- No inbound TLS listeners, no HTTPS server surface area.

This module is intended for **low-volume** remote API calls (LLM providers, SaaS APIs, etc.).

## Build

`lunet.httpc` is a separate optional xmake target.

Prerequisites:
- libcurl development package available via `pkg-config` (Linux/macOS) or vcpkg (Windows).

Build (release):

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y
xmake build lunet-bin
xmake build lunet-httpc
```

Output:
- `build/<platform>/<arch>/<mode>/lunet/httpc.so` (or `.dll` on Windows)

Then in Lua:

```lua
local httpc = require("lunet.httpc")
```

## API

### `httpc.request(opts) -> resp, err`

Must be called from a yieldable coroutine spawned by `lunet.spawn`.

#### `opts`
- `url` (string, required)
- `method` (string, optional, default `"GET"`)
- `headers` (table, optional)
  - map form: `{["Header"]="value"}`
  - array form: `{{"Header","value"}, ...}`
- `body` (string, optional)
- `timeout_ms` (integer, optional, default `30000`)
- `max_body_bytes` (integer, optional, default `10485760` = 10 MiB)
- `insecure` (boolean, optional)
  - if omitted: inherits from `LUNET_HTTPC_INSECURE` environment variable (truthy enables insecure)
  - if provided: explicit override

#### `resp`
On success:
- `status` (number)
- `body` (string)
- `headers` (array) of `{ name=string, value=string }` (duplicates preserved)
- `effective_url` (string, optional)

On failure: `resp == nil` and `err` is a string error message.

## TLS Verification Policy

TLS certificate verification is **enabled by default**.

Development-only escape hatch:
- Set `LUNET_HTTPC_INSECURE=1` to disable verification by default.
- Prefer leaving this unset in production. Disabling verification defeats TLS security.

## Notes

- This module is **outbound only**. For inbound HTTPS, Lunet’s recommended security architecture is to terminate TLS at an edge proxy and forward to Lunet over a Unix socket or TCP loopback.
