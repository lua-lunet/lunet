# PAXE：数据包加密扩展模块

PAXE（Packet Encryption，数据包加密）是 Lunet 的安全数据包加密扩展，专为需要在应用层进行点对点加密/解密的应用而设计。

## 架构

PAXE 是一个**扩展模块**，具有以下特点：
- 依赖 **libsodium** 进行加密操作
- 使用 **AES-256-GCM** 进行认证加密
- 支持标准模式和 DEK（数据加密密钥）模式
- 执行**原地解密**以减少内存拷贝
- 提供原生 **Lua 绑定**，易于集成

```
应用层 (Lua)
    ↓ require("lunet.paxe")
PAXE Lua 绑定 (C)
    ↓
PAXE 核心 (C)
    ↓
libsodium (AES-256-GCM)
```

## 构建 PAXE

### 前置条件
- libsodium 开发头文件（Linux 上为 `libsodium-dev`，macOS 通过 Homebrew 安装）
- LuaJIT 和 libuv（标准 Lunet 依赖）

### 配置与构建

```bash
# 安装 libsodium (macOS)
brew install libsodium

# 安装 libsodium (Linux)
apt-get install libsodium-dev

# 构建 PAXE 扩展模块
xmake build lunet-paxe
```

### 构建产物
- 发布版：`build/macosx/arm64/release/lunet/paxe.so`
- 调试版：`build/macosx/arm64/debug/lunet/paxe.so`

## 快速失败的依赖检查

如果 libsodium 不可用，构建会在**配置阶段立即失败**并给出清晰的错误信息：

```bash
$ xmake build lunet-paxe
# ERROR: libsodium package not found
#   Install via: brew install libsodium (macOS)
#   Install via: apt-get install libsodium-dev (Linux)
#   Install via: vcpkg install libsodium (Windows)
```

## Lua API

```lua
local paxe = require("lunet.paxe")

-- 初始化
local ok, err = paxe.init()          -- 初始化 PAXE + libsodium
paxe.shutdown()                       -- 清理

-- 启用/禁用
paxe.set_enabled(true)                -- 启用加密
local enabled = paxe.is_enabled()     -- 检查是否启用

-- 密钥管理（密钥必须恰好为 32 字节）
local ok, err = paxe.keystore_set(key_id, key_string)
paxe.keystore_clear()                 -- 安全擦除所有密钥

-- 失败策略："DROP"、"LOG_ONCE" 或 "VERBOSE"
paxe.set_fail_policy("DROP")

-- 加密（标准模式）
local ciphertext, err = paxe.encrypt(plaintext, key_id)

-- 解密
local plaintext, key_id, flags = paxe.try_decrypt(ciphertext)
-- 失败时返回 nil, error_string

-- 统计信息
local stats = paxe.stats()
-- stats.rx_total, stats.rx_ok, stats.rx_auth_fail 等

-- 常量
paxe.OVERHEAD_STANDARD  -- 36 字节（头部 + 随机数 + 标签）
paxe.OVERHEAD_DEK       -- 82 字节（DEK 模式开销）
paxe.VERSION            -- 模块版本字符串
```

## C API

### 初始化
```c
int paxe_init(void);                    // 初始化 PAXE + libsodium
void paxe_shutdown(void);                // 清理
int paxe_is_enabled(void);               // 检查是否启用
void paxe_set_enabled(int enabled);      // 启用/禁用
```

### 密钥管理
```c
int paxe_keystore_set(uint32_t key_id, const uint8_t key[32]);
int paxe_keystore_clear(void);           // 从内存中擦除密钥
```

### 数据包操作
```c
ssize_t paxe_try_decrypt(uint8_t *buf, size_t len,
                         uint32_t *out_key_id,
                         uint8_t *out_flags);
// 返回值：成功时返回明文长度，失败时返回 -1
// 原地解密，将明文移动到缓冲区起始位置
```

### 统计与策略
```c
typedef struct {
    uint64_t rx_total;          // 接收的总数据包数
    uint64_t rx_ok;             // 成功解密的数据包数
    uint64_t rx_short;          // 数据包过短
    uint64_t rx_len_mismatch;   // 长度不匹配
    uint64_t rx_no_key;         // 未找到密钥
    uint64_t rx_auth_fail;      // 认证失败
    uint64_t rx_reserved_nonzero;
} paxe_stats_t;

void paxe_stats_get(paxe_stats_t *out);
void paxe_set_fail_policy(paxe_fail_policy_t policy);  // DROP, LOG_ONCE, VERBOSE
```

## 数据包格式

### 标准模式 (AES-256-GCM)
```
头部 (8) | 随机数 (12) | 密文+标签 (N+16)
```

### DEK 模式（含数据加密密钥）
```
头部 (8) | KEK_随机数 (12) | 加密的DEK (32) | DEK_随机数 (12) | DEK_长度 (2) | 密文+标签 (N+16)
```

## 示例

请参阅 `examples/` 目录中的可运行代码：

- **`examples/06_paxe_encryption.lua`** - 完整的 API 演练，包含加密/解密往返
- **`examples/07_paxe_stress.lua`** - 可配置迭代次数、数据包大小和密钥数量的压力测试

### 快速开始

```lua
local paxe = require("lunet.paxe")

-- 初始化
paxe.init()

-- 设置密钥（需要 32 字节）
paxe.keystore_set(1, string.rep("K", 32))

-- 加密
local ciphertext = paxe.encrypt("Hello, PAXE!", 1)

-- 解密
local plaintext, key_id, flags = paxe.try_decrypt(ciphertext)
print(plaintext)  -- "Hello, PAXE!"

-- 清理
paxe.keystore_clear()
paxe.shutdown()
```

## 测试

### 运行示例
```bash
# 运行加密演示
./build/macosx/arm64/release/lunet-run examples/06_paxe_encryption.lua

# 运行压力测试（默认 1000 次迭代）
./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua
```

### 压力测试
```bash
# 高负载测试
ITERATIONS=10000 PACKET_SIZE=1500 NUM_KEYS=256 \
  ./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua
```

### 使用追踪功能
```bash
# 使用详细追踪构建
xmake f -c -y --lunet_trace=y --lunet_verbose_trace=y
xmake build lunet-paxe

# 运行并通过 stderr 查看日志
./build/macosx/arm64/debug/lunet-run examples/06_paxe_encryption.lua 2>&1 | grep PAXE
```

## 性能

基准测试（macOS arm64，Apple Silicon，发布版构建）：
- 吞吐量：约 400,000 次/秒（加密 + 解密周期）
- 带宽：约 400 MB/秒（1KB 数据包）
- 开销：每个数据包 36 字节（标准模式）
- 硬件 AES-256-GCM 加速

## 安全注意事项

1. **密钥派生**：密钥必须为 32 字节（256 位）。使用 KDF（HKDF、Argon2）从密码派生。
2. **随机数处理**：PAXE 通过 libsodium 为每个数据包生成随机 12 字节随机数。
3. **认证**：解密失败的数据包始终被丢弃（防止预言攻击）。
4. **密钥擦除**：`keystore_clear()` 使用 `sodium_memzero()` 防止密钥被恢复。
5. **基于策略的日志**：使用 `LOG_ONCE` 在不产生噪音的情况下检测攻击。

## 构建标志

| 标志 | 用途 | 使用场景 |
|------|------|---------|
| `LUNET_PAXE` | 启用 PAXE 编译 | 始终（由 xmake 目标设置） |
| `LUNET_TRACE` | 调试追踪 + 计数器 | 开发/调试 |
| `LUNET_TRACE_VERBOSE` | 逐事件 stderr 日志 | 详细调试 |

## 限制

- **单线程**：密钥存储不是线程安全的。如需多线程使用，请加锁保护。
- **无密钥轮换 API**：通过清除并重新添加密钥来实现轮换。
- **无压缩**：PAXE 仅提供加密功能。如需压缩请结合其他模块使用。

## 未来增强

- [ ] 带版本控制的逐对等端密钥轮换
- [ ] 硬件 AES 检测 + 回退
- [ ] ChaCha20-Poly1305 支持（AES-GCM 的替代方案）
- [ ] Perfetto 追踪集成

## 参考资料

- libsodium：https://doc.libsodium.org/
- AES-256-GCM：https://en.wikipedia.org/wiki/Galois/Counter_Mode
- Lunet 架构：参见 README.md 和 AGENTS.md
