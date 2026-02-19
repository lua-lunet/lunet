# lunet.httpc（出站 HTTPS 客户端）

`lunet.httpc` 是 Lunet 的一个**可选**、**仅客户端**的 HTTPS 模块，基于 **libcurl** 构建。

设计目标：
- 在 Lunet 中发起出站 HTTPS 请求，无需启动外部进程（不使用 `curl` 子进程）。
- 协程友好 API：`request()` 会 **yield** 并在完成后恢复调用协程。
- 不提供入站 TLS 监听器，不增加 HTTPS 服务器攻击面。

该模块适用于**低吞吐/低并发**的远程 API 调用（LLM 提供商、SaaS API 等）。

## 构建

`lunet.httpc` 是一个独立的可选 xmake 目标。

前置条件：
- libcurl 开发包可通过 `pkg-config`（Linux/macOS）或 vcpkg（Windows）被发现。

构建（release）：

```bash
xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n -y
xmake build lunet-bin
xmake build lunet-httpc
```

输出：
- `build/<platform>/<arch>/<mode>/lunet/httpc.so`（Windows 为 `.dll`）

Lua 中使用：

```lua
local httpc = require("lunet.httpc")
```

## API

### `httpc.request(opts) -> resp, err`

必须在 `lunet.spawn` 创建的可 yield 协程中调用。

#### `opts`
- `url`（string，必填）
- `method`（string，可选，默认 `"GET"`）
- `headers`（table，可选）
  - 映射形式：`{["Header"]="value"}`
  - 数组形式：`{{"Header","value"}, ...}`
- `body`（string，可选）
- `timeout_ms`（integer，可选，默认 `30000`）
- `connect_timeout_ms`（integer，可选，默认与 `timeout_ms` 相同，且必须 `<= timeout_ms`）
- `max_body_bytes`（integer，可选，默认 `10485760` = 10 MiB）
- `max_header_bytes`（integer，可选，默认 `65536` = 64 KiB）
- `max_header_lines`（integer，可选，默认 `256`）
- `follow_redirects`（boolean，可选，默认 `true`）
- `max_redirects`（integer，可选，默认 `8`）
- `low_speed_limit_bps`（integer，可选，默认 `0`）
- `low_speed_time_sec`（integer，可选，默认 `0`）
  - 必须与 `low_speed_limit_bps` 同时设置（或都为 `0`）
- `allow_file_protocol`（boolean，可选，默认 `false`）
- `insecure`（boolean，可选）
  - 未提供时：继承环境变量 `LUNET_HTTPC_INSECURE`（真值将默认不校验证书）
  - 提供时：显式覆盖

#### `resp`
成功时：
- `status`（number）
- `body`（string）
- `headers`（array），元素为 `{ name=string, value=string }`（保留重复头）
- `effective_url`（string，可选）

失败时：`resp == nil` 且 `err` 为字符串错误信息。

## TLS 校验策略

默认**开启** TLS 证书校验。

仅用于开发的逃生阀：
- 设置 `LUNET_HTTPC_INSECURE=1` 可默认关闭证书校验。
- 生产环境建议保持未设置。关闭校验会破坏 TLS 安全性。

## 响应体积加固

`lunet.httpc` 在两层执行限制：
- libcurl 选项层（超时、重定向上限、协议限制、低速保护、最大文件大小提示）
- 回调层的头部/正文硬限制（`max_header_bytes`、`max_header_lines`、`max_body_bytes`）

对于有明确上限的 API（例如 JMAP），建议显式设置：
- `max_body_bytes` 按服务端上限加少量解析余量
- `max_header_bytes` / `max_header_lines` 按威胁模型收紧
- 将重定向和允许协议控制在最小集合

## 备注

- 该模块仅用于**出站**请求。对于入站 HTTPS，Lunet 推荐的安全架构是在边缘代理终止 TLS，然后通过 Unix 套接字或 TCP 环回转发给 Lunet。
