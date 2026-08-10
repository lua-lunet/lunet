# PAXE：数据报加密扩展模块

PAXE（Packet Encryption）是 lunet 的数据报加密扩展：为集群提供经认证的、加密的点对点 UDP 流量，由 Lua 驱动。它一次保护一个 UDP 载荷——没有握手、没有会话、不保证顺序、不带重放窗口。

协议核心是 **[paxe-core](https://github.com/lua-lunet/paxe-core)**，一个零依赖的 sans-io Rust crate，按上游发布 tag **逐字节内嵌**（vendored）到 `ext/paxe/paxe-core/`（tag、提交与归档摘要记录在 `ext/paxe/paxe-core.version`；用 `xmake vendor-paxe` 重新内嵌）。lunet 侧的 crate `ext/paxe` 拥有 C ABI 并构建出 `liblunet_paxe` 动态库，`require("lunet.paxe")` 通过加载器 `ext/paxe/paxe.lua` 以 LuaJIT FFI 加载它——与 `lunet.jsonic` 的加载模型相同。该扩展是纯可选的：绝不链接进 `lunet-run`。

**规范性的线路格式与安全契约**是 paxe-core 的 [PAXE.md](https://github.com/lua-lunet/paxe-core/blob/v0.1.0/PAXE.md)。本文档是 lunet 集成参考：描述 Lua API 的行为，仅复述 lunet 运维人员会接触到的线路契约部分。若本文档与上游契约不一致，以上游文档为准——请报告此类漂移。

## 概览

- 每一帧都使用 **AES-256-GCM** 认证加密，经由 libsodium（静态链接进动态库）
- **每条链路一个 32 字节预共享密钥**（按无序节点对），带外注入；线上无密钥协商，无 SRP，无证书
- 密钥按 **(对端节点 id, epoch)** 寻址——5 位 epoch（0–31）随认证范围内的标志字节传输，使轮换成为一套流程而非一次切换日
- **发送方向只有标准帧**：`paxe.seal` 在任何载荷大小下都产生标准的单接收者帧——不存在按大小选择模式
- **接收方向支持可复用 DEK 扇出帧**：`paxe.open` 可透明打开由 Rust 扇出主机封装的此类帧（C ABI 不提供扇出封装器）
- 通过 `paxe.protect()` 实现**按套接字的 UDP 保护**；刻意不提供进程级总开关
- 丢弃加策略的失败语义：拒绝原因永不透露给调用方（不构成解密预言机）；累积统计计数器是唯一的诊断通道

## 构建

前置条件：Rust 工具链（rustup；`ext/paxe/rust-toolchain.toml` 锁定的版本会在首次使用时自动安装）、用于 libsodium 构建衔接的 C 编译器，以及**静态 libsodium**（`libsodium.a` / `libsodium.lib`）。paxe-core 的构建脚本依次通过 `PAXE_SODIUM_LIB_DIR`、Unix 上的 `pkg-config --libs --static libsodium`、Windows 上的 vcpkg 静态 triplet 路径定位该归档；找不到就硬失败，绝不回退到共享库。Debian/Ubuntu 的 `libsodium-dev` 和 Homebrew 的 `libsodium` 都带有该归档。

```bash
xmake build-paxe     # 在 ext/paxe 中执行 cargo build --release
xmake test-paxe      # 该 crate 的 FFI 边界测试套件（debug + release）
```

构建完全离线：协议核心已内嵌在仓库中（见上文），不涉及任何 git 拉取或凭据。内嵌的树是上游锁定 tag 的 `git archive` 逐字节输出——`xmake vendor-paxe` 可重新解包，`xmake vendor-paxe --tag=vX.Y.Z` 可重新锁定到新的上游发布版（两者都需要对私有上游仓库的读权限）。

### 构建产物

- `ext/paxe/target/release/liblunet_paxe.so`（Linux）、`.dylib`（macOS）、`lunet_paxe.dll`（Windows）
- 加载器是 `ext/paxe/paxe.lua`；`LUNET_PAXE_LIB` 可覆盖它加载的库路径
- 发布归档将两者一并打包为 `lunet/paxe.lua` 加旁边的动态库，自包含（libsodium 为静态链接）

## 从 lunet 视角看的线路格式

所有多字节整数字段均为大端序。每一帧以 9 字节前缀开始：

| 字节 | 字段 | 含义 |
|-------|-------|---------|
| 0–1 | `fromId` | 源节点标识（u16） |
| 2–3 | `toId` | 目的节点标识（u16） |
| 4–5 | `channel` | 信道标识（u16） |
| 6–7 | `length` | **明文**载荷长度（字节） |
| 8 | flags | bit 0：0 = 标准帧，1 = 可复用 DEK 帧；bit 1：必须为 0；bit 2：必须为 1；bit 3–7：密钥 epoch（0–31） |

标志字节**在认证范围内**：标准帧的 AES-GCM AAD 就是这 9 字节前缀本身，因此寻址、模式和 epoch 都无法在不导致认证失败的情况下被篡改。接收方会拒绝任何 bit 1 置位或 bit 2 清零的帧——廉价的垃圾过滤器。

### 标准帧（`paxe.seal` 的产物）

```
Prefix(9) ‖ Nonce(12) ‖ Ciphertext(N) ‖ Tag(16)
```

开销 **37 字节**；65507 字节 UDP 数据报中最大的标准明文为 **65470 字节**。直接在接收方链路密钥下封装，每帧使用新的 CSPRNG 随机数。

### 可复用 DEK 扇出帧（`paxe.open` 可能收到的帧）

Rust 扇出主机对一份载荷只加密一次，为每个接收者发出一个完整数据报；每个接收者数据报的正文字节完全相同，只有前缀和 DEK 信封不同：

```
Prefix(9) ‖ EnvelopeNonce(12) ‖ EncryptedDEK(32) ‖ EnvelopeTag(16) ‖ BodyNonce(12) ‖ BodyCiphertext(N) ‖ BodyTag(16)
```

开销 **97 字节**；最大可复用 DEK 明文为 **65410 字节**。正文在新的 32 字节 DEK 下加密一次；每个接收者的信封是在该接收者链路密钥下封装的 DEK，信封 AAD 把接收者前缀绑定到确切的正文随机数和标签。两个 GCM 标签都必须验证通过才释放任何明文。不存在未认证的密钥包裹，也不存在冗余的内层长度字段。

### 线上的模式

`paxe.seal` 永远封装**标准**帧——载荷大小从不参与模式选择，也没有强制模式的 API。`paxe.open` 只依据验证过的模式标志选择解析器，并报告它打开的模式（`"standard"` 或 `"dek"`）。接收方绝不从载荷或数据报大小推断模式。

## 密钥管理

### 每条链路一个密钥

密钥是 32 字节共享秘密——每个无序节点对一个——由运维带外注入（经 ssh 下发、来自密钥管理器、来自配置）。按链路的粒度是设计中承重的那块安全性质：`fromId` 经过认证，但认证只把 `fromId` 绑定到*持有密钥的人*。在集群级单一密钥下，任何节点都能封装声称任意 `fromId` 的帧；而每对一个密钥时，第三方节点无法伪造 `fromId=A`、`toId=B` 的帧，因为它不持有 A↔B 密钥。

接收方按 **(对端节点 id, epoch)** 定位密钥：对端是帧头 `fromId`，epoch 是标志字节的 bit 3–7，本节点 id 通过 `paxe.set_local_id` 一次性配置。

### 轮换

`paxe.seal` 不接受 epoch 参数：发送 epoch 永远是为该对端安装的**最新 epoch**，因此一旦安装新 epoch，发送方立即切换。轮换是三步流程，新旧密钥全程共存：

1. 在两端为新 epoch 安装新密钥；旧 epoch 保持安装。
2. 新 epoch 安装的那一刻，发送方即已切换。
3. 确认没有发送方再用旧 epoch 后，将其退役（`paxe.keystore_retire`）。

滚动重启即可在无切换日、无丢包的情况下轮换整个集群。

### 密钥存储

已安装的密钥保存在 Rust 库拥有的、带保护页、`mlock` 锁定、释放时清零的 libsodium 分配中；密钥材料从不向外穿越 FFI。`paxe.init` 注册一个 `atexit` 钩子，即使脚本从不调用 `paxe.shutdown()`，也会在正常进程退出时擦除密钥库。崩溃路径的平台差异见[安全注意事项](#安全注意事项)。

## 限制

最大 UDP 数据报为 65507 字节。最大明文载荷由每帧开销决定：

| 模式 | 开销 | 最大载荷 | 可用途径 |
|------|----------|-----------------|---------------|
| 标准 | 37 | **65470** | `paxe.seal` |
| 可复用 DEK | 97 | **65410** | 仅接收来自 Rust 扇出主机的帧（`paxe.open`） |

以超大载荷封装会以操作性错误失败，错误消息指明标准模式最大值（`nil, message`），并计入 `tx_oversize`。长度字段绝不会为塞进帧而截断：截断的长度会产生一个对端必然拒绝的帧，而调用方得不到任何错误。

## 失败处理

无法解析、认证或解密帧的接收方会**丢弃它**。拒绝原因刻意不返回给调用方，也从不向发送方发出信号：一个解释伪造帧*为何*失败的接收方就是解密预言机。`paxe.open` 把一切帧级失败——过短、标志违例、长度不一致、未知对端、未知 epoch、认证失败，甚至未配置的密钥库——收敛为一个结果：`nil, "lunet.paxe: frame rejected"`。

丢弃行为由进程级失败策略控制，用 `paxe.set_fail_policy` 选择：

| 策略 | 行为 |
|--------|-----------|
| `silent`（默认） | 丢弃；仅计数 |
| `log_once` | 每个窗口内每种原因的首次丢弃向 stderr 记录一行（一条 `[PAXE]` 行），其后静默计数 |
| `verbose` | 每次丢弃都记录 |

由于原因永不到达调用方，**统计计数器是唯一的诊断通道**。它们是进程级、累积的 `u64` 值，进程存活期间永不清零——`shutdown()` 也不清零。请测量两次 `paxe.stats()` 快照之间的**差值**，绝不要断言绝对值：

| 计数器 | 含义 |
|---------|---------|
| `rx_total` | 提交给已配置接收方的帧数（打开 + 丢弃） |
| `rx_ok` | 成功打开的帧数 |
| `rx_plaintext` | 丢弃：根本不是发给本节点的 PAXE 帧——不足 9 字节前缀，或帧头 `toId` 不是本节点 id。由套接字边界上的显式寻址检查捕获，绝不靠标志字节 |
| `rx_short` | 丢弃：短到无法解析（不足 9 字节前缀，或 DEK 位置位时不足 97 字节可复用 DEK 最小值） |
| `rx_bad_flags` | 丢弃：标志常量位违例（bit 1 置位或 bit 2 清零）——廉价垃圾过滤器 |
| `rx_len_mismatch` | 丢弃：声明的明文长度与实际帧大小不一致（两种模式共用的唯一长度一致性计数器） |
| `rx_no_peer` | 丢弃：帧的 `fromId` 在任何 epoch 下都没有密钥——**拓扑**问题（该链路从未开通） |
| `rx_no_epoch` | 丢弃：`fromId` 已开通但没有该帧 epoch 的密钥——**轮换**问题 |
| `rx_auth_fail` | 丢弃：AES-GCM 标签验证失败（密钥错误、密文或 AAD 被篡改、DEK 信封或正文被篡改） |
| `tx_total` | 成功封装的帧数 |
| `tx_standard` | `tx_total` 中标准封装的数量——经此 API 永远等于全部 |
| `tx_dek` | Rust 主机记录的可复用 DEK 扇出帧数（此 API 从不推动它） |
| `tx_oversize` | 因载荷过大被拒绝的封装次数 |

**不变量：** `rx_total == rx_ok + sum(所有拒绝原因)`。提交给已配置接收方的每一帧都恰好落入其中一个桶。（两条路径刻意在统计之外：提交给*未配置*接收方的帧——模块根本没在运行 PAXE——以及不可能出现的内部结果，它们不是线路状态。）

两条记录在案的策略决策：

- **log_once 重置范围。** log_once 备忘在 `shutdown()` 时重置，也在策略被设为 `log_once` 时重置——重新进入该策略就是运维人员"再告诉我一次"的旋钮。攻击者无法重置备忘，因此在一个窗口内每种原因最多记录一次，无论流量多大；这种备忘化就是限流。
- **日志行不含 `fromId` 或 epoch。** 拒绝时刻可用的每个字段都是攻击者可控且*未经验证*的——这正是帧被丢弃的原因。记录这些字段会让未认证发送方按策略频率向运维日志写入貌似真实的对端身份：一条欺骗通道。日志行只带原因，并有固定的 `[PAXE] ` 前缀，以便与 trace 构建的 stderr 输出区分。

## 信道

信道 1–99 保留给系统流量；应用信道从 100 开始，信道 0 允许使用。信道字段经过认证（在 AAD 内）但不加密。

## 安全注意事项

1. **密钥大小与存储**：密钥恰好 32 字节，是长期共享秘密。静态保护好它们，并带外注入。
2. **随机数处理**：每次 AES-GCM 调用（每一帧、每一个扇出信封）都使用经 libsodium 生成的全新 12 字节随机数。对集群级密钥，随机数核算也是集群级的：生日界适用于聚合调用次数，约 2^32 次调用时 96 位碰撞概率仍低于 2^-32——轮换策略必须按整个集群计数，而不是按单条链路。
3. **认证失败**：一律按失败策略丢弃——绝不产生向调用方或发送方解释失败原因的错误（不构成解密预言机）。
4. **帧头暴露**：前缀经认证但不加密。`fromId`、`toId`、`channel`、`length` 和 epoch 对被动观察者可见。
5. **没有硬件路径就没有 PAXE**：`paxe.init()` 将 AES-256-GCM 不可用报告为错误，绝不回退到软件实现。没有硬件路径的 libsodium 构建或 CPU 无法运行此扩展——这是设计使然。（平台说明：Debian trixie arm64 发行版的 `libsodium` 包构建时未启用 ARM crypto-extension AES 路径，因此即使硬件支持，`init()` 也会报告不可用；修复方法是使用带 ARM CE 路径构建的 libsodium——源码构建或 Homebrew——而不是改动 lunet。Linux CI 正因如此从源码构建 libsodium 1.0.22。）
6. **核心转储（平台差异）**：已安装的密钥位于带保护页、`mlock` 锁定的 libsodium 分配中。`mlock` 在所有平台上都让这些页面不进交换分区，但核心转储排除各不相同：在 Linux 上，libsodium 的 `mlock` 会设置 `MADV_DONTDUMP`；在 macOS 上没有这种排除（Darwin 没有 `MADV_DONTDUMP`）。因此 `paxe.init()` 默认对整个进程禁用核心转储（`setrlimit(RLIMIT_CORE, 0)`，仅软限制；继承的硬限制保留）。该 rlimit 是进程级的，这是合理的，因为加载 PAXE 本身就是选择加入。**调试时重新启用**：启动前设置 `LUNET_PAXE_ALLOW_CORE_DUMPS=1`（`ulimit -c unlimited`、`lldb -c /cores/...` 照常可用）；绝不要在生产节点上设置——在 macOS 上，崩溃会把活跃密钥材料写入核心文件。操作系统层面也有纵深防御可用（`ulimit -c 0`）。

## Lua API（`lunet.paxe`）

该模块是 Rust 动态库 `liblunet_paxe`，由 `ext/paxe/paxe.lua` 通过 LuaJIT FFI 加载；`LUNET_PAXE_LIB` 可覆盖库路径。所有加密状态——密钥库，即全部密钥材料——都保存在 FFI 之后的 Rust 库内部；Lua 除了传入密钥的瞬间外从不持有密钥（见[密钥材料与 Lua VM](#密钥材料与-lua-vm已知限制)）。

### 函数

| 函数 | 返回值 | 含义 |
|----------|---------|---------|
| `paxe.version()` | string | paxe-core crate 版本（`"0.1.0"`）。 |
| `paxe.init()` | `true` \| `nil, message` | 初始化 libsodium 并要求 AES-256-GCM 硬件路径。幂等。当主机无法提供时返回 `nil, message`——PAXE 拒绝运行，绝不替换为其他密码。`init` 的第一步还会禁用进程核心转储（见[安全注意事项](#安全注意事项)）。 |
| `paxe.set_local_id(node_id)` | `true` | 配置本节点身份（0–65535）——一次。未经 `shutdown()` 的第二次调用会抛出错误：静默重建密钥库会抹掉已安装的密钥。 |
| `paxe.keystore_set(peer, epoch, key)` | `true` \| `nil, message` | 在 `epoch`（0–31）下安装与 `peer`（0–65535）共享的 32 字节密钥。覆盖已占用的槽位会擦除旧密钥。 |
| `paxe.keystore_retire(peer, epoch)` | `true` \| `false` \| `nil, message` | 擦除一个 `(peer, epoch)` 槽位。槽位本为空时返回 `false`（信息性，不是错误）。 |
| `paxe.keystore_clear()` | `true` | 擦除所有已安装的密钥。 |
| `paxe.seal(payload, to_id, channel)` | `frame` \| `nil, message` | 在 `channel` 上把 `payload`（字符串）封装为发给 `to_id` 的**标准**帧——永远如此，与载荷大小无关。`fromId` 是已配置的本节点 id——永不是参数，因此没有调用方能伪造来源。发送 epoch 是为 `to_id` 安装的最新 epoch（见[轮换](#轮换)）。`channel` 必须容纳于 16 位且不在保留的系统范围 1–99 内（信道 0 允许）。 |
| `paxe.open(frame)` | `payload, from_id, channel, mode` \| `nil, message` | 打开一个收到的帧——标准帧，或来自 Rust 扇出主机的可复用 DEK 帧。成功时：明文、经认证的 `fromId`、信道、模式（`"standard"` 或 `"dek"`）。任何失败：`nil` 加同一条不透明消息——见[失败处理](#失败处理)。 |
| `paxe.stats()` | table | 进程级累积计数器的快照（13 个字段；见[失败处理](#失败处理)）。永不清零；测量快照间的差值。 |
| `paxe.set_fail_policy(name)` | `true` \| `false` | 选择丢弃日志策略：`"silent"`（默认）、`"log_once"`、`"verbose"`——大小写不敏感。其他拼写或非字符串参数返回 `false`。 |
| `paxe.protect(udpsock, config)` | `true` | 让一个 `lunet.udp` 套接字加入保护：之后的 `udp.send` 先封装再发送，`udp.recv` 先打开再交付（见 [UDP 套接字保护](#udp-套接字保护)）。`config.peer`（必填）是此套接字封装目标的节点 id；`config.channel`（可选，默认 `0`）是封装信道。对非句柄套接字、畸形配置或模块未配置的情况抛出错误——给未配置的模块布防会静默丢弃每一个数据报。 |
| `paxe.unprotect(udpsock)` | `true` | 移除套接字的保护。幂等。 |
| `paxe.is_protected(udpsock)` | `false` \| `true, peer, channel` | 查询套接字的保护状态及其配置的对端/信道。 |
| `paxe.shutdown()` | — | 清零并释放所有密钥，遗忘本节点身份。幂等；之后 `set_local_id` 可重新配置。统计计数器**不**重置（它们在进程存活期内累积）；log_once 备忘会重置。正常进程退出时的密钥擦除不依赖此调用：`init` 注册的 `atexit` 钩子即使脚本从不调用 `shutdown()` 也会清零密钥库。 |

任何地方都没有 `key_id`：密钥按 `(对端节点 id, epoch)` 寻址。也刻意没有 `set_enabled`/`is_enabled`：保护是按套接字的 `paxe.protect`（见下），它真正控制行为。

### 错误约定

同一约定，统一适用：

- **畸形参数抛出** Lua 错误——那是调用脚本里的 bug。错误的 Lua 类型由加载器检查；越界和违反约束的值由 Rust 检查，每条消息都指明约束：节点 id 容纳于 16 位（0–65535），epoch 容纳于 5 位（0–31），信道容纳于 16 位且遵守 1–99 保留范围，密钥恰好 32 字节。
- **操作性失败返回 `nil, message`**——脚本需要处理的情况：未初始化或未配置、AES-256-GCM 不可用、对端未安装密钥、载荷超过标准模式最大值、密钥库已满、安全内存失败。

任何输入都无法让进程崩溃：库以 `panic = "abort"` 构建，Rust panic 会杀死 LuaJIT 宿主。因此每个穿越 FFI 边界的值都经过验证（加载器查类型，Rust 查范围和长度），每个检查都返回而不是 panic。

### UDP 套接字保护

`paxe.protect(udpsock, config)` 让一个套接字加入 PAXE。这是记录在案的按套接字决策：没有进程级开关，因为单一全局开关无法表达同时服务加密集群端口和未加密本地端口的进程——而且被删除的 C 模块的全局开关是个只打印 "enabled" 的空操作。以按套接字保护作为唯一机制，就没有先后优先级问题需要文档化。`paxe.unprotect` 解除套接字保护，`paxe.is_protected` 查询，`udp.close` 也会移除套接字的保护条目（被释放句柄的指针可能被后来的 bind 复用，绝不能继承陈旧的保护配置）。

**集成在 Lua 侧，不在 `src/udp.c`。** Rust 核心已通过 FFI 可从 Lua 到达；`require("lunet.udp")` 返回一个普通的 C 函数 Lua 表，因此 `protect` 拦截该共享表上的 `send`/`recv`/`close`，只把已注册套接字路由进加密路径——未保护的套接字直接落入原始 C 函数。若改为接入 C 侧，则需要一条新的通往 Rust 的 C ABI，并且加密会运行在 udp.c 的接收回调里——那运行在 libuv 事件循环上而不是 Lua 协程上，正是项目调试笔记中记载的 use-after-free 崩溃场景。C 回调与 `udp_ctx_t` 原封不动，永远接触不到密钥材料。

**解密发生在交付时刻**，即 Lua 调用 `udp.recv` 时——而不是 libuv 回调中的到达时刻。因此 C 接收队列持有的是密文，从不是明文：到达与 `recv` 之间没有打开的明文滞留于 C 内存，排空队列时也不需要密钥材料。`udp.close` 的队列冲刷会丢弃从未认证的密文——不计数，因为它从未到达下面的关口——对反正无法交付的帧来说，这与丢弃是同一终态。

接收方向每个数据报的顺序是：

1. **显式明文关口。** 一个数据报只有至少携带 9 字节前缀且帧头 `toId` 等于已配置的本节点 id，才被当作 PAXE 帧。其他一切——明文、异种协议或错投流量——都被丢弃并计入 `rx_plaintext`，依据是寻址检查，绝不是标志常量位关口：精心构造的明文可能让第 8 字节通过该关口，而当两者同时成立（普通垃圾）时，移动的是 `rx_plaintext` 而不是 `rx_bad_flags`。
2. **打开。** 发往本节点的数据报进入 `open`。成功时 `udp.recv(sock)` 返回 `data, host, port, from_id, channel`——明文、传输层发送方地址、经认证的 `fromId` 和信道。任何失败都按失败策略处理，原因计数器移动，且**不交付任何东西**——没有数据，没有错误指示；`recv` 只是继续等待下一个数据报。等待过程中的关闭或错误原样透传（`nil, nil, message`）。

发送方向，`udp.send(sock, host, port, data [, peer [, channel]])` 在传输前封装 `data`：对端取自调用或套接字配置，信道同理（默认 `0`），发送 epoch 是为该对端安装的最新 epoch，永远是标准帧。封装失败——未配置、对端无密钥、载荷超大——使发送以指明原因的清晰错误失败；不传输任何内容，超大计入 `tx_oversize`。

丢弃可见性：trace 构建中 udp.c 的 `UDP_TRACE_RX` 追踪数据报到达；每一次丢弃都在 Rust 中计数并通过失败策略报告（`log_once`/`verbose` 下的 `[PAXE] drop: <reason>` 行）——与同步 `open` 使用的是同一机制，没有平行机制。

**进程退出时的密钥擦除由运行时负责**：`paxe.init` 注册一个 `atexit` 钩子，即使脚本从不调用 `shutdown()`，也会在正常终止时清零并释放密钥库。`abort()`/`SIGKILL` 时没有钩子能运行；那种情形的缓解按平台分列（[安全注意事项](#安全注意事项)第 6 条）：在 Linux 上，受保护页面的 `MADV_DONTDUMP` 使它们不进内核核心转储；在 macOS 上（无此排除），缓解手段是 `init` 默认的核心转储抑制——根本不写核心转储。

### 常量

`paxe.OVERHEAD_STANDARD`（37）、`paxe.OVERHEAD_DEK`（97）、`paxe.MAX_PAYLOAD_STANDARD`（65470）和 `paxe.MAX_PAYLOAD_DEK`（65410）在加载时从 Rust 库读取——由构建帧的同一层计算，绝不在 Lua 中复述为字面量。DEK 那对常量描述的是本机可能*收到*的可复用 DEK 扇出帧；C ABI 只封装标准帧。（被删除的 C 实现曾在 `#define` 和文档中硬编码 36 和 82，两处以同样方式出错。单一事实来源，导出即用。）

### 密钥材料与 Lua VM（已知限制）

密钥以 Lua 字符串形式到达模块，而 Lua 字符串活在 Lua VM 内：被驻留、被垃圾回收、不可变，且可被 VM 自由复制，位于模块无法擦除的、无保护的、可交换内存中。因此把 32 字节密钥传给 `keystore_set` 会让该副本暴露到 VM 恰好释放它为止。模块带保护、mlock、释放清零的存储只保护 Rust 持有的副本——它无法保护 Lua 持有的副本。这是真实限制，如实说明而非粉饰。

**记录在案的决策：** Lua 字符串是本发布版唯一的密钥装载路径。Rust 侧的文件加载器——把配置好的密钥文件直接读入受保护内存，字节完全不经过 VM——是候选的后续工作，本次刻意不包含。无法接受 VM 过境的运维方，在该功能落地前必须把进程镜像和交换分区当作携带密钥材料对待——正如他们对任何经 Lua 配置的秘密本就该做的那样。

## 示例与测试

- `examples/06_paxe_encryption.lua`——API 导览（从 init 到受保护的 UDP 套接字）
- `examples/07_paxe_stress.lua`——压力测试：每个操作都做字节级断言，并对账所有计数器
- `spec/paxe_spec.lua`——Lua 边界的行为测试套件（随 `xmake test` 运行；动态库未构建时挂起为 pending）
- `test/smoke_paxe.lua`——独立冒烟测试（`lunet-run test/smoke_paxe.lua`）
- `test/run_paxe_udp_e2e.sh`——双进程受保护 UDP 回环端到端测试
- 线路格式本身（已知答案向量、篡改矩阵、两种帧几何）由 paxe-core 自己的 `cargo test` 套件固定，在该仓库运行——lunet 按发布的 tag 逐字节内嵌，因此格式不可能在 lunet 发布版下悄悄改变，除非有一次经评审的 `xmake vendor-paxe` 重新锁定提交

## 参考文献

- paxe-core（协议核心与规范性线路契约）：https://github.com/lua-lunet/paxe-core（[PAXE.md](https://github.com/lua-lunet/paxe-core/blob/v0.1.0/PAXE.md)）
- libsodium：https://doc.libsodium.org/
- AES-256-GCM：https://en.wikipedia.org/wiki/Galois/Counter_Mode
- Lunet 架构：见 README.md 与 AGENTS.md
