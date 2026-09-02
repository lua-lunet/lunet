# Sodium：加密原语扩展模块

`lunet.sodium` 是一个**极简的 libsodium 原语接口**：一次性 SHA-256、一次性 HMAC-SHA-256（即 JWT HS256 原语）以及 `randombytes`。只有三个函数，没有更多。

它存在的原因是：PAXE 的 cdylib（`liblunet_paxe`）已经**静态链接了 libsodium** —— 二进制发布包的每个使用者，其随包携带的库里就已经包含了这些普通原语的字节。在此之前这些原语无法触达（静态链接的 sodium 符号并不从 cdylib 导出），脚本被迫加载**第二个** libsodium（macOS 上用 Homebrew，Linux 上用发行版软件包）—— 一个进程里出现两份 sodium，还带来 `dlsym(RTLD_DEFAULT)` 的歧义。`lunet.sodium` 让已经在那里的原语变得可用。

本模块通过 LuaJIT FFI 从 **dylib 句柄**（对 cdylib 路径执行 `ffi.load`）加载，绝不经过 `ffi.C` / `RTLD_DEFAULT` —— 因此同一进程里用户自行加载的 libsodium 永远无法截获这个查找。它与 `lunet.paxe`、`lunet.jsonic` 使用同一套加载模型，并且同样是纯可选的：没有任何东西被链接进 `lunet-run`。

## 概览

| 函数 | 用途 | libsodium 原语 |
|------|------|----------------|
| `sodium.sha256(data)` | 校验和、内容摘要 | `crypto_hash_sha256` |
| `sodium.hmac_sha256(data, key)` | JWT HS256 签名/验证、MAC | `crypto_auth_hmacsha256` |
| `sodium.random(n)` | 不可预测字节（id、盐、nonce） | `randombytes_buf` |

为什么是这三个：SHA-256 与 HMAC-SHA-256 覆盖了校验和与 JWT HS256 —— 从 Lua 里使用 sodium 最常见的原因。`randombytes_buf` 是自然的搭档，因为任何进程都不应混用两个随机数发生器；这里的随机数来自 **PAXE 生成 nonce 与 DEK 所用的同一个 CSPRNG**。

## 依赖与加载

需要 PAXE cdylib：源码检出后执行 `xmake build-paxe`，或使用二进制发布包中的 `lunet/liblunet_paxe.*`（加载器 `lunet/sodium.lua` 与其同目录，并按自身相对路径找到它）。不需要任何 PAXE 配置 —— 这些原语与 `lunet.paxe` 只共享 cdylib，不共享状态：无需 `paxe.init()`、无需 `set_local_id()`，也不会触碰 PAXE 的统计计数器。

| 环境变量 | 作用 |
|----------|------|
| `LUNET_SODIUM_LIB` | 覆盖本加载器绑定的 cdylib 路径（优先检查） |
| `LUNET_PAXE_LIB` | 同上，与 `ext/paxe/paxe.lua` 共用（其次检查） |

与 PAXE 不同，这里**没有 AES-256-GCM 硬件要求** —— 这些是可移植的软件原语，在所有平台上可用，包括 Windows（`lunet.lnt_shared` / `lunet.jsonic` 不随 Windows 包发布）。

## Lua API（`lunet.sodium`）

所有输出都是**原始二进制字符串**（哈希函数为 32 字节，random 为 `n` 字节）。请自行格式化 —— 本模块刻意不提供 hex/base64 辅助函数。

```lua
local sodium = require("lunet.sodium")
```

### `sodium.BYTES`

`sha256` 与 `hmac_sha256` 输出的摘要/标签字节长度：32。

### `sodium.sha256(data) -> digest`

对 `data`（字符串，可含 NUL 等任意字节）做一次性 SHA-256。返回 32 字节摘要。

### `sodium.hmac_sha256(data, key) -> tag`

对 `data` 做一次性 HMAC-SHA-256。`key` 必须**恰好 32 字节** —— libsodium 固定的 HMAC-SHA-256 密钥长度（`crypto_auth_hmacsha256_KEYBYTES`）；长度错误会抛出异常。返回 32 字节标签。

### `sodium.random(n) -> bytes`

从系统 CSPRNG 抽取 `n` 个不可预测字节。`n` 为非负整数；0 返回空字符串。

### 错误约定

与 `lunet.paxe` 形状一致：

- **畸形参数抛出** Lua 错误，并指明参数名与约束 —— 它们是调用脚本的 bug。
- **操作性失败**（libsodium 初始化失败 —— 环境属性）返回 `nil, 消息`。

在正常主机上操作性失败不可达：这些函数自行初始化 libsodium（幂等），而这三个原语没有其他失败模式。

### 示例：校验和

```lua
local sodium = require("lunet.sodium")

local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

print(hex(sodium.sha256("abc")))
-- ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
```

### 示例：JWT HS256 签名输入

HS256 是对 `header.payload` 字节做 HMAC-SHA-256，密钥为 base64url 解码后的秘密（RFC 8725 要求解码后的密钥至少 32 字节 —— 恰好是本 API 的密钥长度）：

```lua
local sodium = require("lunet.sodium")

local signing_input = header_b64u .. "." .. payload_b64u
local sig = sodium.hmac_sha256(signing_input, secret_32bytes)
-- 验证方：对收到的签名做常数时间比较是调用者的职责；对
-- HMAC-SHA-256 而言用 == 比较标签并不会泄露可利用的信息，
-- 但常数时间比较是纪律上的默认选择。
```

## 独立 FFI（不依赖 lunet-run）

任何 LuaJIT 程序都可以直接加载该 cdylib。完整的导出面是三个符号（外加用于错误消息的共享符号 `lunet_paxe_last_error`）：

```lua
ffi.cdef[[
  int lunet_sodium_sha256(const uint8_t* input, size_t input_len, uint8_t* out);
  int lunet_sodium_hmac_sha256(const uint8_t* input, size_t input_len,
                               const uint8_t* key, size_t key_len, uint8_t* out);
  int lunet_sodium_randombytes(uint8_t* out, size_t out_len);
  const uint8_t* lunet_paxe_last_error(size_t* len);
]]
```

返回码：

| 码 | 含义 |
|----|------|
| `0` | 成功 |
| `-2` | 畸形参数（在需要字节处传了空指针、密钥长度错误）—— 消息见 `lunet_paxe_last_error` |
| `-1` | 操作性失败（libsodium 初始化）—— 消息见 `lunet_paxe_last_error` |

调用者契约：`out` 缓冲区必须对写入长度有效 —— 两个哈希输出为 32 字节，random 为 `out_len` 字节。长度为 0 的 `lunet_sodium_randombytes` 是成功的空操作。

## ABI 承诺，以及刻意不做出的承诺

**承诺：** 上面的三个 `lunet_sodium_*` 符号，及其签名与返回码，在每一个随附 PAXE cdylib 的发布中保持不变。

**刻意不承诺：**

- **不整体导出 libsodium 命名空间。** 内置的 sodium 版本不能成为公共 ABI 承诺，整体导出也会与用户自行加载的 sodium 产生符号冲突隐患。如果你需要本接口没有的原语，请加载你自己的加密库 —— 本模块不会一个符号一个符号地长成一个影子 libsodium。
- **不提供流式/增量变体。** 一次性哈希与 HMAC 已覆盖 JWT 场景；流式 API（`crypto_hash_sha256_*_init/update/final`）不被暴露。
- **这里没有密钥环或保护内存。** 该角色由 `lunet.paxe` 保留；本接口绝不触碰 PAXE 的密钥库、节点身份、计数器或失败策略。

## 安全考量

- **无状态哈希不跨越任何秘密。** `sha256` 的输入就是脚本要哈希的内容；调用结束后不保留任何东西。
- **HMAC 密钥材料确实跨越 FFI。** 32 字节密钥是普通的 Lua 字符串数据：它在 Lua 虚拟机中未经保护地传递，与传给 `paxe.keystore_set` 的密钥字符串完全一样（诚实的表述见 `docs/PAXE-CN.md`）。受保护、`mlock`、释放即清零的密钥内存仍然由 PAXE 负责；本接口面向普通原语，不负责密钥保管。请据此派生或加载你的 JWT 秘密。
- **一个进程只有一个 RNG。** `sodium.random` 与 PAXE 使用同一个 CSPRNG，同时使用两者的进程永远不会混用两个随机源。
- **输出是原始字节。** 编码（hex、base64url）以及任何填充/长度策略由调用者负责。

## 测试

- `spec/sodium_spec.lua` —— Lua 行为套件（在 `xmake test` 中运行）：FIPS 180-4 的 SHA-256 已知答案、独立实现的 HMAC-SHA-256 已知答案、错误约定、随机数形态检查。
- `ext/paxe/src/lib.rs`（`ffi_tests` 的 sodium 部分）—— 在 C 层直接驱动同样的导出，包括已知答案向量以及空指针/错误长度参数的处理。

## 参考

- [libsodium 文档 — SHA-2](https://doc.libsodium.org/hashing/sha-2)
- [libsodium 文档 — HMAC-SHA-2](https://doc.libsodium.org/advanced/hmac-sha2)
- [libsodium 文档 — 生成随机数据](https://doc.libsodium.org/generating_random_data)
- [RFC 8725 — JWT 最佳现行实践](https://www.rfc-editor.org/rfc/rfc8725)（HS256 与密钥长度要求）
- [`docs/PAXE-CN.md`](PAXE-CN.md) —— 同一个 cdylib 的另一个接口
