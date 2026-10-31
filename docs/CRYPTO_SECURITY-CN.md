# Security：HMAC + JWT 扩展模块

`lunet.security` 是一个可选的 Lua 封装，为 lunet 应用提供每个 Web 应用都需要的认证令牌层：HMAC-SHA-256 签名/验证、base64url 辅助函数，以及 JWT HS256（`encode` / `decode`）。

关键在于加密出自谁之手：每一个加密的字节级操作都来自 libsodium，经 FFI（`liblunet_crypto`，通过 `lunet.sodium`）调用 - 封装层自身不实现任何加密。它在 Lua 中做的唯一组合是基于 `lunet.sodium.sha256` 按 RFC 2104 构造 HMAC-SHA-256（一个密钥填充步骤 - 见下文"密钥处理"），claims JSON 则通过 `lunet.jsonic` 完成。

## 概览

- `security.crypto` - 基于 `lunet.sodium` 的 HMAC-SHA-256 `sign` / `verify`（常数时间比较）以及无填充 base64url `b64url_encode` / `b64url_decode`。
- `security.jwt` - 基于 `security.crypto` + `lunet.jsonic` 的 HS256 `encode` / `decode`：规范化的 `{alg="HS256", typ="JWT"}` 头部、类型检查的头部与 claims、常数时间签名验证、强制 `exp`。外加用于提取并验证 `Authorization` 头的 `bearer` 辅助函数。

## 依赖与加载

扩展声明自己需要什么，运维者负责安装：

| 依赖 | 何时 | 原因 |
|------------|------|-----|
| libsodium（经 `liblunet_crypto`） | 始终需要 - `lunet.sodium` 在加载时 require | HMAC-SHA-256 与 base64 原语 |
| `lunet.jsonic` | 仅 JWT - 首次使用时加载 | claims JSON 编解码；其加载器随本模块一起打包在压缩包中（其原生解码器目前仅限 POSIX） |

在发布压缩包中，各加载器并排位于 `lunet/` 目录下，通过运行时的 `lunet/?.lua` 路径条目解析 - 见 [docs/RELEASE-LAYOUT-CN.md](RELEASE-LAYOUT-CN.md)。在仓库内或任何 LuaJIT 程序中，直接加载文件：

```lua
local security = require("lunet.security")
local crypto, jwt = security.crypto, security.jwt
```

当 `lunet.sodium` 找不到 `liblunet_crypto` 时（用 `xmake build-crypto` 构建），`require("lunet.security")` 会直接失败；缺少 `lunet.jsonic` 只会在首次使用时以一个指名依赖的错误打断 `jwt.*`。

## Lua API（`lunet.security`）

### `security.crypto.sign(data, key) -> tag`

基于原始 secret 八位组的 HMAC-SHA-256，在 `lunet.sodium.sha256` 之上按 RFC 2104 组合而成。返回原始 32 字节标签 - 对任何密钥长度都与普通 HMAC-SHA-256 逐位一致。

`key` 可以是任何非空字符串 - 见下文"密钥处理"。畸形参数会抛出错误；操作失败（libsodium 无法初始化）返回 `nil, message`。

### `security.crypto.verify(data, key, sig) -> ok`

常数时间验证：计算期望标签，然后通过累积的 XOR 差值逐字节与 `sig` 比较 - 工作量不取决于字符串在何处分歧。长度不是 32 字节的 `sig` 直接返回 `false`。返回 `true` 或 `false`；操作失败会重新抛出，而不会悄悄报告为签名不匹配。

### `security.crypto.b64url_encode(data) -> b64`

编码为无填充 base64url - 即 JWT 规格：URL 安全字母表（`-`、`_`），无 `=` 填充 - 使用 `lunet.sodium` 的 URLSAFE 变体。畸形参数会以底层库的诊断信息抛出，与 `lunet.sodium` 本身一致。

### `security.crypto.b64url_decode(data) -> bytes`

通过同一变体将无填充 base64url 解码回字节。畸形输入会以底层库的诊断信息抛出（即 `lunet.sodium.base64_decode` 的约定） - `jwt.decode` 会将其转换为指名 `malformed` 的错误，因为令牌字节是不可信输入；直接调用者则保留抛出行为。

### `security.jwt.encode(payload, secret, opts?) -> token`

编码一个紧凑 JWT。头部固定为 `{alg="HS256", typ="JWT"}`（以规范化字节顺序编码，因此头部段始终是 `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9`）；claims 是 `payload` 经由 `lunet.jsonic` 的 JSON。

`opts.expires_in`（正整数秒）会在 payload 的**副本**上注入 `exp = now + expires_in` - 调用者的表永远不会被修改，且这样设置的 `exp` 优先于 payload 中已有的 `exp`。不传 `expires_in` 时 payload 原样通过，无论有无 `exp` claim。

畸形参数会抛出错误（nil payload、空 secret）；JSON 编码失败（循环引用、不支持的类型）由 `lunet.jsonic` 抛出。

### `security.jwt.decode(token, secret) -> claims, err`

解码并验证一个紧凑 JWT，返回 claims 表，或 `nil` 加上一个指名失败类别的错误字符串：

| 类别 | 错误字符串 | 含义 |
|------|--------------|---------|
| `malformed` | `lunet.security.jwt: malformed: ...` | 不是三个以点分隔的 base64url 段；某个段无法解码；头部或 claims 不是 JSON 对象；头部 `alg` 不是 `HS256`；`exp` claim 不是数字 |
| `sig` | `lunet.security.jwt: sig: signature verification failed` | `header.payload` 上的签名不匹配 - 以常数时间比较 |
| `exp` | `lunet.security.jwt: exp: token expired` | 令牌携带的 `exp` claim 严格早于当前时间 |

签名在任何 JSON 解析**之前**验证，因此令牌主体的任何字节除了 MAC 覆盖的字节外不会影响任何东西。`alg` 检查在签名检查之后运行，且拒绝 `HS256` 之外的任何算法 - alg 混淆令牌（例如 `{"alg":"none"}` 头部）即使在其签名真实有效时也会被拒绝为 `malformed`。

### `security.jwt.bearer(authorization, secret, schemes) -> claims, kind`

针对 `Authorization` 头的提取加验证辅助函数：只做机制，不做策略。`schemes`
列出调用方愿意接受的方案词 - 单个字符串或非空字符串数组 - 与头中的方案
词做不区分大小写的匹配（一个或多个分隔空白，容忍尾部空白），随后用
`jwt.decode` 解码令牌，把每种失败映射为一个简短的类别词，让每个应用保留
自己的错误消息、状态码与匿名回退身份：

```lua
-- RealWorld 规范要求的仅 Token：
local claims, kind = security.jwt.bearer(auth_header, secret, "Token")

-- 或者应用确实需要两者时：
local claims, kind = security.jwt.bearer(auth_header, secret, { "Bearer", "Token" })
```

`schemes` 是必填的：没有默认接受集合，因为"静默地选一个"（RFC 6750 的
方案词 vs 框架的单字方案词）是策略决定，属于应用，不属于这个辅助函数。
省略它、传空数组、传非字符串元素、或传既非字符串也非字符串数组的值，都会
抛出错误 - 那是调用方的 bug，不是攻击者输入。

| `kind` | 含义 |
|--------|------|
| `"missing"` | 头缺失（`nil`）或为空字符串 |
| `"scheme"` | 头存在，但其方案词不在接受集合中，或后面没有令牌 |
| `"malformed"` | 解码侧检查失败：令牌形状、base64、JSON、`alg` 不是 HS256，或 `exp` 不是数字 |
| `"sig"` | 签名不匹配 |
| `"exp"` | 令牌的 `exp` 严格早于当前时间 |

成功时返回 claims 表和 `nil`。非字符串且非 nil 的头、或坏的 secret 会抛出
错误 - 那是调用方的 bug，不是攻击者输入。该辅助函数刻意**不做**的事：挑选
错误消息、选择响应状态码、或回退到匿名身份。那是策略，策略留在应用里。

## 密钥处理

HS256 遵循 RFC 7518：HMAC-SHA-256 的密钥就是**原始 secret 八位组** - 标准 JWT 库用来签名和验证的正是这些字节。本模块产生的和接受的标签恰好就是这些标签，secret 长度不限。

libsodium 的 `crypto_auth_hmacsha256` 将 HMAC 密钥固定为恰好 32 字节，而 `lunet.sodium` 刻意拒绝任何其他长度，而不是悄悄填充或截断 - 因此本模块在 `lunet.sodium.sha256` 之上用 Lua 组合 HMAC-SHA-256（仍是 libsodium 的哈希，经 FFI），遵循 RFC 2104：

- **长于 64 字节块的密钥先做哈希** - 这是标准自身的归约，长密钥产生的标签与普通 HMAC-SHA-256 完全一致；
- **其余任何密钥按原样使用**，按 HMAC 自身的填充方式零填充到块大小 - 这正是短 secret（`"Jefe"`、`"secret"`、二十个 `0x0b` 字节）能验证标准库所签发标签的原因。

结果对任何密钥长度都与普通 HMAC-SHA-256 逐位一致 - 没有子密钥派生，不会对短 secret 重新哈希。sign 与 verify 共享同一个密钥处理辅助函数，因此只要两侧使用相同 secret，该策略对调用者不可见。

## exp 策略

- **没有** `exp` claim 的令牌永不过期 - `decode` 成功。
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

-- 每个需要认证的请求上：把头的值直接交给 jwt.bearer
-- （框架没有该头时为 nil，此时返回 "missing"）。
local function auth_user(header)
  local claims, kind = jwt.bearer(header, SECRET)
  if not claims then
    return nil, kind  -- missing / scheme / malformed / sig / exp
  end
  return claims
end
```

## 打包

`lunet/security.lua` 与 `sqlite3.lua` 并排随每个发布压缩包发布 - 一个没有自己二进制产物的 Lua 模块；其加密由 libsodium 提供，经 `liblunet_crypto` 链接。`lunet/sodium.lua`、`lunet/paxe.lua` 和 `lunet/jsonic.lua`（依赖项）随其一同发布；见 [docs/RELEASE-LAYOUT-CN.md](RELEASE-LAYOUT-CN.md)。

## 测试

`spec/security_spec.lua` 覆盖：基于原始 secret、由独立实现计算的 HMAC 已知答案向量（RFC 4231 测试用例 1 和 2 逐字走原始密钥路径，用例 5 和 7 走标准的先哈希密钥路径，以及针对固定 JWT 签名输入、外部计算的短 secret 签名）、子密钥派生标签不通过验证的负向钉死、逐字节篡改拒绝、base64url RFC 4648 向量与二进制往返、JWT 编码/解码往返（包括使用短原始 secret 的标准库令牌）、`exp` 策略、alg 混淆防御，、bearer 提取验证的各类别，以及每个指名错误字符串。当 `liblunet_crypto`（或 jsonic 的原生解码器）尚未构建时，测试套件会干净地 pend。

## 参考

- RFC 2104 - HMAC：消息认证的键控哈希
- RFC 4231 - HMAC-SHA-256 测试用例
- RFC 4648 - Base16、Base32 与 Base64 数据编码（URL 安全规格）
- RFC 7518 - JSON Web 算法（HS256：对原始 secret 八位组做 HMAC-SHA-256）
- RFC 7515/7519 - JSON Web 签名 / JSON Web 令牌
- [docs/SODIUM-CN.md](SODIUM-CN.md) - 底层原语及其安全边界（HMAC 密钥以普通 Lua 字符串数据跨越 FFI）
