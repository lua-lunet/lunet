# lunet.http / lunet.http_context / lunet.http_router

构建于 `lunet.socket` 之上的纯 Lua HTTP/1.1 三件套：

- [`lunet.http`](#lunethttp--请求解析与响应构建) — 请求解析、响应构建、可选 CORS
- [`lunet.http_context`](#lunethttpcontext--每请求上下文) — 每请求全新的上下文对象
- [`lunet.http_router`](#lunethttprouter--路由与中间件) — 带 `:参数` 与中间件的方法+路径分发

没有 C 核心，也没有新依赖：这些模块是普通的 Lua 文件，在发布压缩包中与
`sqlite3.lua` 并排随包发布（见 [docs/RELEASE-LAYOUT-CN.md](RELEASE-LAYOUT-CN.md)）。
从源码构建时，`xmake build-release` 会把它们复制到 `lunet-run` 旁边，运行时的
`lunet/?.lua` 路径条目即可解析到。套接字 I/O（listen、accept、read、write、
close）由调用方负责；JSON 辅助函数仅在被调用时才惰性地依赖 `lunet.jsonic`。

这三件套移植自 [RealWorld 示例应用](https://github.com/lua-lunet/realworld-lua)，
并剥离了应用特有的形态；中间件与 CORS 是移植过程中恢复的约定。可运行的端到端
示例见 [`examples/08_http.lua`](../examples/08_http.lua)。

## 帧格式子集

解析器刻意只支持一个小而明确的 HTTP/1.1 子集：

- 每个连接一个 origin-form 请求，CRLF 换行的头字段
- 每个头字段至多一个值，可选的十进制 `Content-Length` 请求体
- 拒绝 `Transfer-Encoding`（包括 chunked）
- 响应总是声明 `Connection: close` —— 无流水线、无持久连接；写完响应后请关闭套接字
- `MAX_HEADER_BYTES`（16 KiB）与 `MAX_BODY_BYTES`（1 MiB）保护解析器；
  超大请求头以 431 失败，超大请求体以 413 失败

解析失败遵循 `nil, message, status` 约定，连接循环可以直接用
`http.error_response(status, { message })` 应答。

## lunet.http — 请求解析与响应构建

```lua
local http = require("lunet.http")
```

| 函数 | 返回 | 说明 |
|------|------|------|
| `http.parse_request(raw)` | `request, err, status` | 解析一个完整的原始请求（头 + 体）。请求体必须与 `Content-Length` 完全一致。 |
| `http.read_request(read_chunk)` | `request, err, status` | 增量变体：反复调用 `read_chunk()` 直到请求完整；读取器返回字符串分块，EOF/失败时返回 nil 加可选错误信息。 |
| `http.response(status, headers, body, cors?)` | `string` | 构建完整响应。帧格式由本函数负责：调用方的 `Content-Length`/`Connection` 头会被丢弃并替换（`Content-Length` 取自请求体，`connection` 恒为 `close`）。`Content-Type` 默认为 `application/json`。 |
| `http.json_response(status, data, cors?)` | `string` | `response()`，数据经 JSON 编码。 |
| `http.error_response(status, data, cors?)` | `string` | `json_response()`，数据包装为 `{"errors": data}`。 |
| `http.parse_query_string(query)` | `table` | 将 `a=1&b=2` 解码为表；值经过 URL 解码。 |
| `http.url_decode(str)` | `string` | `%xx` 字节转义。 |
| `http.cors_headers(cors)` | `table` | 根据配置（见下）生成 `Access-Control-*` 头集合。 |
| `http.is_preflight(request)` | `boolean` | `OPTIONS` 请求且同时带有 `Origin` 与 `Access-Control-Request-Method` 时为真。 |
| `http.preflight_response(cors)` | `string` | 携带所配置 CORS 头、空请求体的 200 —— 即预检短路响应。 |

解析出的请求是一个全新的表：

```lua
request.method        -- "GET"（大写）
request.path          -- "/counters/hits"（已去掉查询串）
request.version       -- "HTTP/1.1"
request.headers       -- { [小写头名] = 值 }
request.body          -- 缺省时为 ""
request.raw           -- 原始字节（仅 read_request 提供）
request.query_string  -- "by=2"（缺省时为 ""）
request.query_params  -- { by = "2" }（URL 解码后）
```

典型的连接循环：

```lua
local function handle_connection(client)
  local request, err, status = http.read_request(function()
    local chunk, read_err = socket.read(client)
    if not chunk then return nil, read_err end
    return chunk
  end)
  if not request then
    socket.write(client, http.error_response(status or 400, { err }))
    socket.close(client)
    return
  end
  if cors and http.is_preflight(request) then
    socket.write(client, http.preflight_response(cors))
  else
    local ctx = http_context.new(request)
    ctx.env_config = config
    router.handle(ctx)
    socket.write(client, http.response(ctx.status, ctx.res_headers, ctx.response_body(), cors))
  end
  socket.close(client)
end
```

## lunet.http_context — 每请求上下文

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

## lunet.http_router — 路由与中间件

```lua
local router = require("lunet.http_router")
```

路由器是模块级单例：路由模块在被 require 时自行注册，连接循环只负责接好套接字。

```lua
-- routes/articles.lua —— require 时自行注册
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

处理器契约 —— 处理器以 `pcall(handler, ctx.env_config, ctx, params)` 运行：

- 返回**表**：JSON 编码后作为响应体；带 `status` 字段的表会设置响应状态码，
  其 `body` 字段（若存在）则替代整表成为编码载荷
- 返回**字符串**：原样写出，状态码 200，`Content-Type: application/json`
- 返回**其他任何值**（包括不返回）：由处理器自己通过 `ctx.write()`/`ctx.status`
  驱动响应，上下文保持处理器写入的原样

每个被分发的响应都通过 `ctx.write()` 写出并带 `Content-Type: application/json`；
状态码 204 写空响应体。未知路径 —— 或路径匹配但方法不支持的请求 —— 报 404，
响应体为 `{"error":"Not found","path":...}`。处理器或中间件的错误不会外抛：
通过 `ctx.log("err", ...)` 记录，并以 500 与 `{"error":"Internal server error"}`
响应体应答。

### 中间件

`router.use(fn)` 注册分发前中间件。中间件按注册顺序在路由分发之前运行，并与
处理器共用同一错误契约：

- 中间件可以**短路**：返回表或字符串 —— 该值与处理器返回值完全同法落地
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
`http.preflight_response`），以及把配置作为最后一个实参传给
`http.response`/`http.json_response`/`http.error_response` 处理其余请求。

## 示例

[`examples/08_http.lua`](../examples/08_http.lua) 将三件套接到作为刻意简化的
kv 存储的 `lnt_shared` 计数器上 —— GET 读取计数器、POST 递增、PATCH 按 JSON
增量调整 —— 并带有日志中间件、403 短路守卫和已启用的 CORS：

```bash
xmake build-release          # 同时把 ext/http 的 Lua 模块复制到 lunet-run 旁边
xmake build-lnt-shared       # 构建计数器的底层存储
"$LUNET_BIN" examples/08_http.lua
```

## 类型

LuaCATS 注解位于扩展文件中的每个公开函数上；Teal 镜像见
[`types/lunet/http.d.tl`](../types/lunet/http.d.tl)。把 `types/` 放入编辑器的
工作区库即可获得补全与签名帮助（见 [docs/RELEASE-LAYOUT-CN.md](RELEASE-LAYOUT-CN.md)）。
