# lunet.websocket（WebSocket 服务端模块）

`lunet.websocket` 是 Lunet 的一个**可选** WebSocket 服务端模块。

设计目标：
- 通过 **wslay**（成熟的 C 库）处理 RFC6455 帧协议。
- 提供 Lua 友好的两类接入方式：
  - 独立 WebSocket 端口
  - 同端口 HTTP/1.1 Upgrade
- 不改变既有入站安全架构（边缘代理 + Unix 套接字/环回）。

## 构建

`lunet.websocket` 是独立的可选 xmake 目标。

前置条件：
- `wslay` 开发包可通过 `pkg-config`（Linux/macOS）或 vcpkg（Windows）被发现。

构建（release）：

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y
xmake build lunet-bin
xmake build lunet-websocket
```

输出：
- `build/<platform>/<arch>/<mode>/lunet/_websocket.so`（Windows 为 `.dll`）

Lua 入口：

```lua
local ws = require("lunet.websocket")
```

## API

### 独立监听

- `ws.listen(protocol, host, port, opts?) -> listener, err`
- `ws.accept(listener, opts?) -> conn, err`

`protocol` 支持 `\"tcp\"` 和 `\"unix\"`（与 `lunet.socket` 策略一致）。

`opts`（`listen` / `accept`）支持：
- `registry: boolean` - 启用按监听器注册表。
- `max_header_bytes: integer` - HTTP Upgrade 请求头最大字节数（默认 `65536`）。
- `max_message_size: integer` - 入站 WebSocket 单消息最大字节数（默认 `8388608`，即 8 MiB）。

### 同端口 HTTP + WS Upgrade

- `ws.is_upgrade_request(req) -> boolean`
- `ws.read_http_request(client, max_header_bytes?) -> req, err`
- `ws.upgrade(client, req?, opts?) -> conn, err`

`opts`（`upgrade`）支持：
- `listener: websocket_listener` - 可选监听器，用于注册表归属。
- `subprotocol: string` - `Sec-WebSocket-Protocol` 响应头值。
- `max_header_bytes: integer` - 仅在省略 `req` 且内部读取请求时生效。
- `max_message_size: integer` - 入站 WebSocket 单消息最大字节数（默认 `8388608`）。

### 连接读写

- `ws.recv(conn) -> data, opcode | nil, err`
- `ws.send(conn, data, opcode?) -> true | nil, err`
- `ws.ping(conn, data?) -> true | nil, err`
- `ws.close(conn, code?, reason?) -> true`
- `ws.id(conn) -> integer`

Opcode 常量：
- `ws.TEXT == 1`
- `ws.BINARY == 2`
- `ws.CLOSE == 8`
- `ws.PING == 9`
- `ws.PONG == 10`

### 注册表（显式启用）

- 按监听器：
  - `ws.listen(..., { registry = true })`
  - `ws.connections(listener) -> {conn, ...}`
  - `ws.broadcast(listener, data, opcode?) -> sent_count, first_err`
- 全局：
  - `ws.enable_global_registry()`
  - `ws.global_registry.find_by_id(id) -> conn | nil`
  - `ws.global_registry.broadcast_all(data, opcode?) -> sent_count, first_err`

## 握手加密

`Sec-WebSocket-Accept` 由 LuaJIT FFI 在 Lua 层计算：
- macOS：`CC_SHA1`（CommonCrypto，系统运行库）
- Linux/其他：`libcrypto` 的 `SHA1`

如果以上 SHA1 后端都不可用，`ws.upgrade()` / `ws.accept()` 会显式返回错误。
此时需要安装可用的系统加密库。

## 背压行为

当前原生绑定会在 C 与 Lua 之间排队已解析完成的消息，因此同一 TCP 包中包含多帧
（突发消息）不会被丢弃。

当队列扩容内存分配失败时，连接会被关闭并显式返回解码错误。

该模块不会增加入站 TLS 监听能力。生产环境建议在边缘层终止 TLS，并通过 Unix 套接字或环回将流量转发到 lunet。
