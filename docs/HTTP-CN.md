# lunet.http / lunet.http_context / lunet.http_router

构建于 `lunet.socket` 之上的纯 Lua HTTP/1.1 三件套：

- [`lunet.http`](#lunethttp--请求解析与响应构建) - 请求解析、响应构建、可选 CORS
- [`lunet.http_context`](#lunethttpcontext--每请求上下文) - 每请求全新的上下文对象
- [`lunet.http_router`](#lunethttprouter--路由与中间件) - 带 `:参数` 与中间件的方法+路径分发

这些模块是普通的 Lua 文件，没有 C 核心，也没有新依赖：它们随发布压缩包发布
（压缩包内容见 [docs/RELEASE-LAYOUT-CN.md](RELEASE-LAYOUT-CN.md)）。从源码构建
时，`xmake build-release` 会把它们复制到 `lunet-run` 旁边，运行时的
`lunet/?.lua` 路径条目即可解析到。套接字 I/O（listen、accept、read、write、
close）由调用方负责；JSON 辅助函数仅在被调用时才惰性地依赖 `lunet.jsonic`。

可运行的端到端示例见 [`examples/08_http.lua`](../examples/08_http.lua)。

## 帧格式子集

先说部署安全：[docs/SECURITY_ARCHITECTURE-CN.md](SECURITY_ARCHITECTURE-CN.md)
中的 qmail 式模型 - 一台久经考验的 nginx（或同类）在网络接口上终结 TLS，
通过回环接口与你本地的 lunet 进程对话；若你更想用文件系统权限而非 IP 规则，
也可以用 Unix 域套接字。本模块的示例只绑定回环；它不是 TLS 终结器，也永远
不应是。

本模块实现的帧格式是 HTTP/1.1 中一个刻意很小的子集：

解析器刻意只支持一个小而明确的 HTTP/1 子集：

- origin-form 请求，CRLF 换行的头字段；一个连接按顺序逐个服务请求，
  直到连接关闭；线上已缓冲的请求也会被服务（流水线，见下）
- 每个头字段至多一个值，可选的十进制 `Content-Length` 请求体
- `Transfer-Encoding: chunked` 被接受（大小写不敏感、单独且为最后一个
  编码），请求体在服务前先解码；任何其他传输编码答 501
- 带 `Host` 头的 HTTP/1.0 请求被接受并以 `Connection: close` 服务；任何
  版本缺失 `Host` 答 400，HTTP/0.9（没有版本号）答 400
- 连接默认持久（HTTP/1.1）：响应不携带 `Connection` 头。把 `persistent=false`
  作为最后一个实参传给 `http.response`/`http.json_response`/`http.error_response`
  （以及 `http.preflight_response`）即可声明 `Connection: close` 响应。
- 请求声明 `Connection: close` 时会被尊重：用 `persistent=false` 构建其响应，
  并在写出后结束连接循环。HTTP/1.0 请求携带 `request.persistent_connection =
  false`，同样以该方式构建响应并关闭
- 要服务线上已缓冲的请求，用 `http.new_connection` 包装连接的分块读取器，
  每个请求调用一次 `next_request()`：一个请求未消费的字节就是下一个请求的
  输入。单次 `http.read_request` 保持旧的高严格契约：越过声明请求体的字节
  得到硬性 400
- `MAX_HEADER_BYTES`（16 KiB）、`MAX_BODY_BYTES`（1 MiB）与
  `MAX_REQUEST_LINE_BYTES`（8 KiB）保护解析器
- 拒绝时携带 RFC 9112 状态码：语法与 Host 违规答 400，非 1.x 大版本答 505，
  不支持的传输编码答 501，超长请求行答 414，超大请求头答 431，超大请求体答
  413，仅方法不对时路由器答 405 并带 Allow 头

解析失败遵循 `nil, message, status` 约定，连接循环可以直接用
`http.error_response(status, { message })` 应答。

这一类解析器不只由规格测试覆盖，还有探针验证：[Http11Probe](https://github.com/uNetworkingAB/Http11Probe)
探针装置（`ext/http/Dockerfile.http`）对本目录下的快乐路径目标运行它的
213 例矩阵并固化断言结果。范围之外的用例通过，是因为子集**有意拒绝**该特性
 - 非chunked 的 `Transfer-Encoding` 答 501，`OPTIONS *`
答 400，最小 echo 目标对未注册方法答 405 并带 `Allow` 头。`ext/http`
代码变更时重跑装置并提交再生成的期望清单：

```sh
docker build -f ext/http/Dockerfile.http -t lunet-http-probe .
docker run --rm -v "$(pwd)/ext/http:/out" lunet-http-probe
```

挂载运行（清单模式）会把该次运行的产物写入挂载目录：`probe-results.json`
（原始响应，评审记录）、`probe-manifest.lua`（镜像内生成的期望清单：
每个 http 模块文件一个 sha256、汇总计数，以及每个探针用例一条
verdict/status 记录），仅此而已。`probe_allowlist.lua` 与它们并列：按设计
的运行结果，清单里每个非 `Pass` 的用例一条。三者一起提交；
`spec/http_probe_spec.lua` 把它们固定住，因此一旦某次运行的结果漂移
（探针版本升级、ext 变更），除非随该次运行同步更新 allowlist，测试套件
就会失败。

## lunet.http - 请求解析与响应构建

```lua
local http = require("lunet.http")
```

| 函数 | 返回 | 说明 |
|------|------|------|
| `http.parse_request(raw)` | `request, err, status` | 解析一个完整的原始请求（头 + 体）。`Content-Length` 请求体必须与声明长度完全一致；chunked 请求体先解码，缓冲区必须停在最后一个分块的终止符处。 |
| `http.read_request(read_chunk)` | `request, err, status` | 单个请求的增量变体：反复调用 `read_chunk()` 直到请求完整；读取器返回字符串分块，EOF/失败时返回 nil 加可选错误信息。越过声明请求体的字节得到硬性 400。 |
| `http.new_connection(read_chunk)` | `connection` | 为顺序服务包装连接的分块读取器：`connection:next_request()` 返回 `request, err, status`，并把剩余字节排队，用于服务线上已缓冲的请求（流水线）。每个打开的连接一个包装对象。 |
| `http.response(status, headers, body, cors?, persistent?)` | `string` | 构建完整响应。帧格式由本函数负责：调用方的 `Content-Length`/`Connection` 头会被丢弃并替换（`Content-Length` 取自请求体）。连接默认持久 - 按 HTTP/1.1 不带 `Connection` 头；`persistent=false` 则声明 `Connection: close`。`Content-Type` 默认为 `application/json`。 |
| `http.json_response(status, data, cors?, persistent?)` | `string` | `response()`，数据经 JSON 编码。 |
| `http.error_response(status, data, cors?, persistent?)` | `string` | `json_response()`，数据包装为 `{"errors": data}`。 |
| `http.parse_query_string(query)` | `table` | 将 `a=1&b=2` 解码为表；值经过 URL 解码。 |
| `http.url_decode(str)` | `string` | `%xx` 字节转义。 |
| `http.cors_headers(cors)` | `table` | 根据配置（见下）生成 `Access-Control-*` 头集合。 |
| `http.is_preflight(request)` | `boolean` | `OPTIONS` 请求且同时带有 `Origin` 与 `Access-Control-Request-Method` 时为真。 |
| `http.preflight_response(cors, persistent?)` | `string` | 携带所配置 CORS 头、空请求体的 200 - 即预检短路响应。 |

解析出的请求是一个全新的表：

```lua
request.method                  -- "GET"（大写）
request.path                    -- "/counters/hits"（已去掉查询串）
request.version                 -- "HTTP/1.1" 或 "HTTP/1.0"
request.headers                 -- { [小写头名] = 值 }
request.body                    -- 缺省时为 ""；chunked 请求体已解码
request.raw                     -- 原始字节（read_request / next_request 提供）
request.chunked                 -- 请求体以 chunked 到达时为 true
request.persistent_connection   -- HTTP/1.0 为 false，其余为 true
request.query_string            -- "by=2"（缺省时为 ""）
request.query_params            -- { by = "2" }（URL 解码后）
```

典型的连接循环 - 一个连接上按顺序服务多个请求（包括线上已缓冲的），在客户端
EOF、帧格式错误、请求声明的 `Connection: close`，或 HTTP/1.0 连接时结束：

```lua
local function handle_connection(client)
  local conn = http.new_connection(function()
    local chunk, read_err = socket.read(client)
    if not chunk then return nil, read_err end
    return chunk
  end)
  while true do
    local request, err, status = conn:next_request()
    if not request and not status then
      -- 任何字节之前遇到 EOF：关闭或空闲的客户端拥有这次关闭。
      socket.close(client)
      return
    end
    if not request then
      -- 帧格式错误会让字节流失去同步：声明 close，停止服务。
      socket.write(client, http.error_response(status or 400, { err }, nil, false))
      socket.close(client)
      return
    end
    local persistent = request.persistent_connection
      and (request.headers["connection"] or ""):lower() ~= "close"
    if cors and http.is_preflight(request) then
      socket.write(client, http.preflight_response(cors, persistent))
    else
      local ctx = http_context.new(request)
      ctx.env_config = config
      router.handle(ctx)
      socket.write(client, http.response(ctx.status, ctx.res_headers,
                                         ctx.response_body(), cors, persistent))
    end
    if not persistent then
      socket.close(client)  -- HTTP/1.0，或请求声明了 Connection: close
      return
    end
  end
end
```

## lunet.http_context - 每请求上下文

```lua
local http_context = require("lunet.http_context")
local ctx = http_context.new(request)
```

每请求一张全新的表，绝不全局共享，因此并发 `lunet.spawn` 协程之间不会共享
可变状态。

| 字段 | 类别 | 说明 |
|------|------|------|
| `ctx.method`、`ctx.path`、`ctx.query`、`ctx.headers`、`ctx.body` | 请求 | 从解析出的请求复制而来；按约定只读。`ctx.query` 是解码后的 `query_params` 表。 |
| `ctx.status` | 响应 | 默认 `200`；由路由器/处理器改写。 |
| `ctx.res_headers` | 响应 | 构建中的响应头表。 |
| `ctx.write(text)` | 响应 | 向响应体追加一块（`nil` 追加 `""`）。 |
| `ctx.log(level, ...)` | 日志 | 写到 stderr；`level` 必须是 `"err"`、`"warn"`、`"notice"`、`"info"`、`"debug"` 之一（其他值会抛错）。 |
| `ctx.response_body()` | 响应 | 读回累计的 `write()` 输出。 |
| `ctx.env_config` | 接线 | 应用配置，由调用方在路由前设置；路由器将其作为第一个实参传给处理器。 |

## lunet.http_router - 路由与中间件

```lua
local router = require("lunet.http_router")
```

路由器是模块级单例：路由模块在被 require 时自行注册，连接循环只负责接好套接字。

```lua
-- routes/articles.lua - require 时自行注册
local router = require("lunet.http_router")

router.route("GET", "/articles/:id", function(config, ctx, params)
  return { article = config.articles[params.id] }
end)
```

| 函数 | 说明 |
|------|------|
| `router.route(method, pattern, handler)` | 注册路由。模式按 `/` 分段；以 `:` 开头的段捕获进 `params`（如 `/users/:id/posts/:post_id`）。段数与字面段的匹配是精确匹配。 |
| `router.match(method, path)` | 返回 `route, params` 或 `nil, nil`。方法比较不区分大小写。 |
| `router.handle(ctx)` | 运行中间件链，分发到匹配的路由，并在上下文上落地响应。 |
| `router.use(fn)` | 注册分发前中间件（见下）。 |
| `router.reset()` | 清空所有路由与中间件（测试、热重载）。 |

处理器契约 - 处理器以 `pcall(handler, ctx.env_config, ctx, params)` 运行：

- 返回**表**：JSON 编码后作为响应体；带 `status` 字段的表会设置响应状态码，
  其 `body` 字段（若存在）则替代整表成为编码载荷
- 返回**字符串**：原样写出，状态码 200，`Content-Type: application/json`
- 返回**其他任何值**（包括不返回）：由处理器自己通过 `ctx.write()`/`ctx.status`
  驱动响应，上下文保持处理器写入的原样

每个被分发的响应都通过 `ctx.write()` 写出并带 `Content-Type: application/json`；
状态码 204 写空响应体。未知路径 - 或路径匹配但方法不支持的请求 - 报 404，
响应体为 `{"error":"Not found","path":...}`。处理器或中间件的错误不会外抛：
通过 `ctx.log("err", ...)` 记录，并以 500 与 `{"error":"Internal server error"}`
响应体应答。

### 中间件

`router.use(fn)` 注册分发前中间件。中间件按注册顺序在路由分发之前运行，并与
处理器共用同一错误契约：

- 中间件可以**短路**：返回表或字符串 - 该值与处理器返回值完全同法落地
  （包括 `{ status, body }` 的解包）
- 返回 `nil`、`false` 或不返回则继续下一个中间件，继而分发
- 中间件出错按 500 记录并应答；路由处理器不会被调用

```lua
router.use(function(ctx)
  print(ctx.method, ctx.path)
end)

router.use(function(ctx)
  if ctx.headers["authorization"] == nil then
    return { status = 401, body = { error = "unauthorized" } }
  end
end)
```

## CORS（可选，默认关闭）

CORS 是无状态的，除非传入配置表，否则完全关闭。配置后，`Access-Control-*`
头会随普通响应一起发送，而 `OPTIONS` 预检会在分发之前由
`http.preflight_response(cors)` 应答。

```lua
local cors = {
  origin = "https://app.example",            -- Access-Control-Allow-Origin
  methods = { "GET", "POST", "PATCH" },      -- 也可以是普通字符串 "GET, POST"
  headers = { "Content-Type", "Authorization" },
  max_age = 600,                             -- Access-Control-Max-Age（预检）
  credentials = true,                        -- Access-Control-Allow-Credentials: true
}
```

配置中省略的键不会产生对应的头；同名键上调用方提供的头始终优先于 CORS 头。
连接循环中的接线只有两处：短路预检（`http.is_preflight` +
`http.preflight_response`），以及把配置作为第四个实参传给
`http.response`/`http.json_response`/`http.error_response` 处理其余请求
（可选的 `persistent` 标志放在最后）。

## 示例

[`examples/08_http.lua`](../examples/08_http.lua) 将三件套接到作为刻意简化的
kv 存储的 `lnt_shared` 计数器上 - GET 读取计数器、POST 递增、PATCH 按 JSON
增量调整 - 并带有日志中间件、403 短路守卫、已启用的 CORS，以及一段 keep-alive
演示（两个请求在一个连接上按顺序服务）：

```bash
xmake build-release          # 同时把 ext/http 的 Lua 模块复制到 lunet-run 旁边
xmake build-lnt-shared       # 构建计数器的底层存储
"$LUNET_BIN" examples/08_http.lua
```

## 类型

LuaCATS 注解位于扩展文件中的每个公开函数上；Teal 镜像见
[`types/lunet/http.d.tl`](../types/lunet/http.d.tl)。把 `types/` 放入编辑器的
工作区库即可获得补全与签名帮助（见 [docs/RELEASE-LAYOUT-CN.md](RELEASE-LAYOUT-CN.md)）。
