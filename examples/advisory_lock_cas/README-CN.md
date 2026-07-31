# 顾问锁 CAS 演示（UDP，双节点）

[English Documentation](README.md)

基于 lunet 协程网络库的双节点顾问锁服务。客户端通过 CAS（比较并交换）
竞争锁持有者；每次写入都先经过 **HIGH** 节点再经过 **LOW** 节点，因此
竞争写入永远只有一个赢家，且两个节点始终收敛一致。

## 演示内容

- 每个进程单个 libuv 事件循环上的 客户端 → 节点 → 对端 → 节点 → 客户端
  中继模式（由 `test/udp_relay_roundtrip.lua` 证明）。
- 从节点的 `ip:port` 地址推导出的确定性写入顺序（标准的锁排序存活性
  论证：全序关系不存在环）。
- 基于 msg_id 关联的对端请求/回复，带超时、有界重试，以及对端不可达
  时的 CAS 守卫回滚。
- 具有 CAS 语义的内存锁表；可以用 `nc` 直接驱动的文本线协议。

## 目录结构

| 文件 | 用途 |
|------|------|
| `node.lua` | 节点进程（3 个 UDP 套接字，3 个协程） |
| `lock.lua` | 纯锁表：`new/get/cas/pack_token`（token = lock_id<<32 \| holder） |
| `codec.lua` | 线协议解析/格式化 |
| `pending.lua` | 用于回复关联的 msg_id 等待表 |
| `config_gen.lua` | 为每个节点发现 2 个空闲端口（共 4 个），写出 Lua 配置 |
| `run_demo.lua` | 端到端驱动（配置 → 节点 → 客户端 → PASS/FAIL） |
| `Makefile` | `test-e2e`、`test-concurrent`、`test-all`、`test-nc`、`clean` |

## 快速开始

```bash
xmake build-release   # 仓库根目录，一次
make -C examples/advisory_lock_cas test-e2e        # 顺序 GET/SET/过期令牌
make -C examples/advisory_lock_cas test-concurrent # 栅栏同步竞争：一个赢家
make -C examples/advisory_lock_cas test-all        # 全部，含超时/nc
```

## 线协议

纯文本，每个数据报一条消息。`lock_id` 和 `holder` 为十进制 `u32`；
`token` 为 16 个小写十六进制字符（`lock_id << 32 | holder`）；`msg_id`
为 8 个十六进制字符，用于将回复关联到请求。

```
GET  /locks/<lock_id> <msg_id>
SET  /locks/<lock_id> <token> <new_holder> <msg_id>
PEER SET /locks/<lock_id> <token> <new_holder> <msg_id>   （节点 → 节点）
PEER GET /locks/<lock_id> <msg_id>                        （节点 → 节点）

REPLY <msg_id> OK <holder> <token>
REPLY <msg_id> CONFLICT <holder> <token>   （携带赢家状态）
REPLY <msg_id> INVALID                     （例如 holder=0 的 SET）
REPLY <msg_id> UNAVAILABLE                 （对端宕机/超时）
```

`holder=0` 是"未持有"哨兵：对从未写入的锁执行 GET 返回 `OK 0 <token>`；
`holder=0` 的 SET 被拒绝为 `INVALID`。

## 角色：HIGH 和 LOW 是推导的，不是配置的

每个节点绑定其客户端套接字后，用 `udp.getsockname` 读取自身地址，并
将 `(ip, port)` 与对端配置的客户端地址进行数值比较。地址较大者为
**HIGH**，较小者为 **LOW**。配置标签 `n1`/`n2` 仅是条目选择器——两个
节点不可能使用同一标签启动（第二个无法绑定端口），客户端地址完全相
同则会中止启动。

- **客户端 SET → HIGH**：本地 CAS；成功后传播到 LOW 并等待 LOW 的应用
  OK，然后才回复。传播超时时，执行 CAS 守卫回滚到提交前状态，并回复
  `UNAVAILABLE`。
- **客户端 SET → LOW**：转发到 HIGH，原样转发 HIGH 的回复。LOW 从不为
  客户端 SET 写自己的状态——因此 LOW 永远不可能提交 HIGH 拒绝的写入，
  HIGH 的 CAS 是唯一的序列化点。
- **传播 → LOW**：幂等应用（对已持有状态的重复/迟到 PEER_SET 是 OK，
  不是冲突）。

**存活性。** 阻塞图是 DAG：只有 LOW 的 peer_listen 处理器从不等待网络
（终点）。所有等待都有界（`PROP_TIMEOUT_MS=250 ×5`，
`FWD_TIMEOUT_MS=500 ×3`），重试也有界，因此无死锁、无活锁。

**回滚限制（演示简化）。** 如果 HIGH 提交了写入 W1，且第二个处理器在
W1 的传播超时之前在同一锁上提交了 W2，则 W1 的守卫回滚无法恢复 W1 之
前的状态（守卫看到的是 W2 的令牌）。W1 的客户端得到 `UNAVAILABLE`，
W2 自己的结果决定最终状态。这种链式情况超出演示范围；单个在途写入
的情况可以精确回滚。

## 用 nc 驱动

回复是发送到发送者地址的数据报，普通的 `nc` 不易打印，因此脚本路径
用 `nc` 发送并用 Lua GET 验证（`make test-nc`）。手动玩耍请开两个终
端：

```bash
# 终端 1：观察请求到达（节点记录每个请求）
make -C examples/advisory_lock_cas test-e2e   # 或通过 run_demo.lua 启动节点
# 终端 2：
printf 'SET /locks/1 0000000100000000 42 aa000001\n' | nc -u -w1 127.0.0.1 <n1_client_port>
printf 'GET /locks/1 bb000002\n'                  | nc -u -w1 127.0.0.1 <n2_client_port>
# 查看 .tmp/logs/<ts>/node_n*.log 中的处理器日志行
```

## 测试

| 目标 | 证明内容 |
|------|----------|
| `test-e2e` | 跨两个节点的顺序 SET/GET/过期令牌 |
| `test-concurrent` | 栅栏同步的并发 SET：恰好一个 OK、一个 CONFLICT，收敛 |
| `test-ordering` | S2：HIGH 宕机时 LOW 从不自行提交 |
| `test-timeout` | SIGSTOP 对端：UNAVAILABLE、无卡死、守卫回滚、恢复后收敛 |
| `test-pending` | msg_id 等待表单元测试（丢弃未知/迟到回复） |
| `test-logs` | 节点日志在运行期间按行缓冲 |
| `test-clean` / `test-quoting` | `make clean` 覆盖仓库根目录；带空格的 `--output` 路径安全 |
| `test-validation` | 拒绝 `holder=0`；codec u32 边界；INVALID/UNAVAILABLE |
| `test-nc` | 通过 `nc` 发送的 SET 在两个节点上都可见 |

## 偏差与后续

- **端口：** 每个节点 2 个（客户端 + 对端监听），共 4 个——符合规格。
- **`lnt` / Rust FFI 计数器：** 尚未使用；锁表是纯 Lua。跟踪于
  [#131](https://github.com/lua-lunet/lunet/issues/131)。
- **`udp.recv` 超时：** 在 Lua 层实现（等待表 + 轮询），不在 C 层；C 层
  超时 API 是未来可能的补充，此处不需要。
- **副本读：** GET 可能晚一次传播才观察到刚提交的远端写入（节点间最
  终一致，这是设计使然）。

## 另见

- `test/udp_relay_roundtrip.lua` —— 中继模式的 go/no-go 证明。
- `.tmp/item00_fix_plan.md` —— 重构计划（issue #130）。
