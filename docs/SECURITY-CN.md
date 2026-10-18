# Security：HMAC + JWT 扩展模块

`lunet.security` 是一个可选的纯 Lua 扩展，为 lunet 应用提供每个 Web 应用都需要的认证令牌层：HMAC-SHA-256 签名/验证、base64url 辅助函数，以及 JWT HS256（`encode` / `decode`）。

它是胶水层，而不是加密库：所有字节级操作都通过现有的 `lunet.sodium` 原语完成，claims JSON 则通过现有的 `lunet.jsonic` 完成。模块自身不做任何哈希、填充或解析。

## 概览

- `security.crypto` —— 基于 `lunet.sodium` 的 HMAC-SHA-256 `sign` / `verify`（常数时间比较）以及无填充 base64url `b64url_encode` / `b64url_decode`。
- `security.jwt` —— 基于 `security.crypto` + `lunet.jsonic` 的 HS256 `encode` / `decode`：规范化的 `{alg="HS256", typ="JWT"}` 头部、类型检查的头部与 claims、常数时间签名验证、强制 `exp`。

## 依赖与加载

依赖契约与数据库驱动相同——扩展声明自己需要什么，运维者负责安装：

| 依赖 | 何时 | 原因 |
|------------|------|-----|
| libsodium（经 `liblunet_paxe`） | 始终需要——`lunet.sodium` 在加载时 require | HMAC-SHA-256 与 base64 原语；PAXE 已静态链接 libsodium，二进制压缩包本就携带这些字节 |
| `lunet.jsonic` | 仅 JWT——首次使用时加载 | claims JSON 编解码；其加载器随本模块一起打包在压缩包中（其原生解码器目前仅限 POSIX） |

在发布压缩包中，各加载器并排位于 `lunet/` 目录下，通过运行时的 `lunet/?.lua` 路径条目解析——见 [docs/RELEASE-LAYOUT-CN.md](RELEASE-LAYOUT-CN.md)。在仓库内或任何 LuaJIT 程序中，直接加载文件：

```lua
local security = require("lunet.security")
local crypto, jwt = security.crypto, security.jwt
```

当 `lunet.sodium` 找不到 `liblunet_paxe` 时（用 `xmake build-paxe` 构建），`require("lunet.security")` 会直接失败；缺少 `lunet.jsonic` 只会在首次使用时以一个指名依赖的错误打断 `jwt.*`。

## Lua API（`lunet.security`）

### `security.crypto.sign(data, key) -> tag`

基于 `lunet.sodium.hmac_sha256` 的 HMAC-SHA-256。返回原始 32 字节标签。

`key` 可以是任何非空字符串——见下文"密钥处理"。畸形参数会抛出错误；操作失败（libsodium 无法初始化）返回 `nil, message`。

### `security.crypto.verify(data, key, sig) -> ok`

常数时间验证：计算期望标签，然后通过累积的 XOR 差值逐字节与 `sig` 比较——工作量不取决于字符串在何处分歧。长度不是 32 字节的 `sig` 直接返回 `false`。返回 `true` 或 `false`；操作失败会重新抛出，而不会悄悄报告为签名不匹配。

### `security.crypto.b64url_encode(data) -> b64`

编码为无填充 base64url——即 JWT 规格：URL 安全字母表（`-`、`_`），无 `=` 填充——使用 `lunet.sodium` 的 URLSAFE 变体。畸形参数会以底层库的诊断信息抛出，与 `lunet.sodium` 本身一致。

### `security.crypto.b64url_decode(data) -> bytes`

通过同一变体将无填充 base64url 解码回字节。畸形输入会以底层库的诊断信息抛出（即 `lunet.sodium.base64_decode` 的约定）——`jwt.decode` 会将其转换为指名 `malformed` 的错误，因为令牌字节是不可信输入；直接调用者则保留抛出行为。

### `security.jwt.encode(payload, secret, opts?) -> token`

编码一个紧凑 JWT。头部固定为 `{alg="HS256", typ="JWT"}`（以规范化字节顺序编码，因此头部段始终是 `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9`）；claims 是 `payload` 经由 `lunet.jsonic` 的 JSON。

`opts.expires_in`（正整数秒）会在 payload 的**副本**上注入 `exp = now + expires_in`——调用者的表永远不会被修改，且这样设置的 `exp` 优先于 payload 中已有的 `exp`。不传 `expires_in` 时 payload 原样通过，无论有无 `exp` claim。

畸形参数会抛出错误（nil payload、空 secret）；JSON 编码失败（循环引用、不支持的类型）由 `lunet.jsonic` 抛出。

### `security.jwt.decode(token, secret) -> claims, err`

解码并验证一个紧凑 JWT，返回 claims 表，或 `nil` 加上一个指名失败类别的错误字符串：

| 类别 | 错误字符串 | 含义 |
|------|--------------|---------|
| `malformed` | `lunet.security.jwt: malformed: ...` | 不是三个以点分隔的 base64url 段；某个段无法解码；头部或 claims 不是 JSON 对象；头部 `alg` 不是 `HS256`；`exp` claim 不是数字 |
| `sig` | `lunet.security.jwt: sig: signature verification failed` | `header.payload` 上的签名不匹配——以常数时间比较 |
| `exp` | `lunet.security.jwt: exp: token expired` | 令牌携带的 `exp` claim 严格早于当前时间 |

签名在任何 JSON 解析**之前**验证，因此令牌主体的任何字节除了 MAC 覆盖的字节外不会影响任何东西。`alg` 检查在签名检查之后运行，且拒绝 `HS256` 之外的任何算法——alg 混淆令牌（例如 `{"alg":"none"}` 头部）即使在其签名真实有效时也会被拒绝为 `malformed`。

## 密钥处理

libsodium 的 `crypto_auth_hmacsha256` 将 HMAC-SHA-256 密钥固定为恰好 32 字节，而 `lunet.sodium` 刻意拒绝任何其他长度，而不是悄悄填充或截断。本模块将固定密钥长度与任意应用密钥调和如下：

- **32 字节的密钥按原样使用**——已知答案向量原样适用；
- **任何其他非空密钥先用 SHA-256 归约到 32 字节**——一种确定性的子密钥派生。长于 HMAC 块大小（64 字节）的密钥派生出与普通 HMAC-SHA-256 完全相同的标签（RFC 2104 也会哈希这类密钥）；较短的密钥被哈希而不是零填充，绝不会像截断那样悄悄丢弃秘密材料。

sign 与 verify 的派生方式一致，因此只要两侧使用相同密钥，该策略对调用者不可见。

## exp 策略

明确声明，因为这是调和后的设计：

- **没有** `exp` claim 的令牌永不过期——`decode` 成功。
- `exp` claim 必须是数字；其他任何类型都是 `malformed`。
- 一旦 `exp` **严格早于**当前时间，令牌即过期。
- 用 `opts.expires_in` 设置过期时间，或自行设置 `payload.exp`。

## 示例：登录时签发令牌，每次请求时验证

```lua
local security = require("lunet.security")
local jwt = security.jwt

local SECRET = os.getenv("JWT_SECRET")  -- 不要把它写进源码树

-- 登录时（校验完凭据之后）：
local token = jwt.encode({ sub = user.id, name = user.name },
                         SECRET, { expires_in = 3600 })

-- 每个需要认证的请求上（Authorization: Bearer 头）：
local function auth_user(header)
  local token = header and header:match("^Bearer%s+(.+)$")
  if not token then return nil, "missing bearer token" end
  local claims, err = jwt.decode(token, SECRET)
  if not claims then return nil, err end  -- malformed / sig / exp
  return claims
end
```

## 打包

`lunet/security.lua` 与 `sqlite3.lua` 并排随每个发布压缩包发布——纯 Lua，没有自己的二进制产物。`lunet/sodium.lua`、`lunet/paxe.lua` 和 `lunet/jsonic.lua`（依赖项）随其一同发布；见 [docs/RELEASE-LAYOUT-CN.md](RELEASE-LAYOUT-CN.md)。

## 测试

`spec/security_spec.lua` 覆盖：独立实现计算的 HMAC 已知答案向量（包括通过长密钥派生路径逐字复现的 RFC 4231 测试用例 5 和 7）、逐字节篡改拒绝、base64url RFC 4648 向量与二进制往返、JWT 编码/解码往返、`exp` 策略、alg 混淆防御，以及每个指名错误字符串。当 `liblunet_paxe`（或 jsonic 的原生解码器）尚未构建时，测试套件会干净地 pend。

## 参考

- RFC 2104 —— HMAC：消息认证的键控哈希
- RFC 4231 —— HMAC-SHA-256 测试用例
- RFC 4648 —— Base16、Base32 与 Base64 数据编码（URL 安全规格）
- RFC 7515/7519 —— JSON Web 签名 / JSON Web 令牌
- [docs/SODIUM-CN.md](SODIUM-CN.md) —— 底层原语及其安全边界（HMAC 密钥以普通 Lua 字符串数据跨越 FFI）
