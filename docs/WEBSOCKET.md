# lunet.websocket (WebSocket Server Module)

`lunet.websocket` is an **optional** WebSocket server module for Lunet.

Design goals:
- RFC6455 frame handling via **wslay** (battle-tested C library).
- Lua-friendly API for both:
  - dedicated WebSocket port
  - HTTP/1.1 Upgrade on the same port
- Keep inbound security architecture unchanged (edge proxy + Unix socket / loopback).

## Build

`lunet.websocket` is a separate optional xmake target.

Prerequisites:
- `wslay` development package available via `pkg-config` (Linux/macOS) or vcpkg (Windows).

Build (release):

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y
xmake build lunet-bin
xmake build lunet-websocket
```

Output:
- `build/<platform>/<arch>/<mode>/lunet/_websocket.so` (or `.dll` on Windows)

Lua entrypoint:

```lua
local ws = require("lunet.websocket")
```

## API

### Dedicated listener

- `ws.listen(protocol, host, port, opts?) -> listener, err`
- `ws.accept(listener, opts?) -> conn, err`

`protocol` supports `"tcp"` and `"unix"` (same policy as `lunet.socket`).

`opts` (for `listen` / `accept`) supports:
- `registry: boolean` - enable per-listener registry.
- `max_header_bytes: integer` - max HTTP upgrade header size (default `65536`).
- `max_message_size: integer` - max inbound WebSocket message size in bytes (default `8388608`, i.e. 8 MiB).

### Mixed HTTP + WS Upgrade

- `ws.is_upgrade_request(req) -> boolean`
- `ws.read_http_request(client, max_header_bytes?) -> req, err`
- `ws.upgrade(client, req?, opts?) -> conn, err`

`opts` (for `upgrade`) supports:
- `listener: websocket_listener` - optional listener for registry ownership.
- `subprotocol: string` - value for `Sec-WebSocket-Protocol` response header.
- `max_header_bytes: integer` - used only when `req` is omitted and request is read internally.
- `max_message_size: integer` - max inbound WebSocket message size in bytes (default `8388608`).

### Connection I/O

- `ws.recv(conn) -> data, opcode | nil, err`
- `ws.send(conn, data, opcode?) -> true | nil, err`
- `ws.ping(conn, data?) -> true | nil, err`
- `ws.close(conn, code?, reason?) -> true`
- `ws.id(conn) -> integer`

Opcode constants:
- `ws.TEXT == 1`
- `ws.BINARY == 2`
- `ws.CLOSE == 8`
- `ws.PING == 9`
- `ws.PONG == 10`

### Registry (opt-in)

- Per-listener:
  - `ws.listen(..., { registry = true })`
  - `ws.connections(listener) -> {conn, ...}`
  - `ws.broadcast(listener, data, opcode?) -> sent_count, first_err`
- Global:
  - `ws.enable_global_registry()`
  - `ws.global_registry.find_by_id(id) -> conn | nil`
  - `ws.global_registry.broadcast_all(data, opcode?) -> sent_count, first_err`

## Handshake Crypto

`Sec-WebSocket-Accept` is computed in Lua via LuaJIT FFI:
- macOS: `CC_SHA1` (CommonCrypto via system runtime)
- Linux/other: `SHA1` from `libcrypto`

If neither SHA1 backend is available, upgrade fails with an explicit error from
`ws.upgrade()` / `ws.accept()`. Install system crypto libraries in that case.

## Backpressure behavior

The native binding queues parsed complete messages between C and Lua so valid
bursts (multiple frames in one TCP segment) are not dropped.

If the runtime cannot allocate memory for queued messages, the connection is
closed and decode fails explicitly.

This module does not add inbound TLS listeners. Use edge TLS termination and proxy to lunet over Unix socket or loopback.
