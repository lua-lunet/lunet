# 贡献指南：工程内部细节

本文档汇集了参与 lunet C 核心开发所需的通用工程知识——命名约定、
调试方法论和测试协议。这是内部参考资料，不会随 SDK 压缩包发布。

关于面向智能体（Agent）的操作规则（超时、防止数据丢失、i18n/类型注解
一致性、发布质量门禁），请参见仓库根目录下的 `AGENTS.md`。

## C 代码约定（严格）

本节定义了 C 代码的命名约定和安全规则，由 `xmake lint` 强制执行。

### 命名约定

| 模式 | 含义 | 用法 |
|------|------|------|
| `_lunet_*` | **内部** - 不安全的原始实现 | 仅用于 `trace.h` 包装器或 `*_impl.c` 文件 |
| `lunet_*` | **公开** - 带追踪的安全包装器 | 其他所有地方均使用 |
| `*_impl.c` | 可以调用 `_lunet_*` 的实现文件 | 罕见，仅用于 trace.h 内部实现 |

**规则**：`trace.h` 和 `*_impl.c` 文件之外的代码禁止直接调用 `_lunet_*` 函数。

**例外（公开 SDK API）**：`include/lunet.h` 中声明的符号
（`lunet_runtime_init`、`lunet_runtime_run_file`、`lunet_runtime_run_embedded`、
`lunet_runtime_shutdown`）是发布 SDK 中提供给下游使用者的嵌入 API。
它们不是对 `_lunet_*` 内部实现的追踪包装器，因此不受包装器约定约束。

### 安全包装器

始终使用 `include/trace.h` 中定义的安全包装器：

| 内部函数（禁止使用）                | 安全包装器（请使用）                  |
|------------------------------------|--------------------------------------|
| `_lunet_ensure_coroutine()`        | `lunet_ensure_coroutine()`           |
| `lua_pushthread()` + `luaL_ref()`  | `lunet_coref_create(L, ref_var)`     |
| `luaL_unref()`（用于 coref）        | `lunet_coref_release(L, ref)`        |

这些安全包装器：
- 在调试构建中（`LUNET_TRACE=ON`）：添加栈完整性检查和引用追踪
- 在发布构建中：编译结果与内部函数完全相同（零开销）

### 新增功能检查清单

在添加使用协程的新 C 插件或功能时：

1. **引入 trace.h**：在源文件中 `#include "trace.h"`
2. **使用安全包装器**：用于协程检查和引用管理
3. **运行 lint**：`xmake lint` 必须通过（不能有直接的 `_lunet_*` 调用）
4. **启用追踪测试**：`xmake stress`（以 `LUNET_TRACE=ON` 构建）
5. **崩溃是好事**：如果追踪断言失败，说明发现了 bug——发布前必须修复
6. **发布构建**：`xmake release` 会先运行测试和压力测试，再进行优化构建

### 示例：异步操作模式

```c
#include "co.h"
#include "trace.h"  // 始终在 co.h 之后引入

int my_async_operation(lua_State *L) {
    // 使用安全包装器——若栈损坏，调试构建下会崩溃
    lunet_ensure_coroutine(L, "my_operation");
    
    // 分配上下文……
    my_ctx_t *ctx = malloc(sizeof(my_ctx_t));
    
    // 使用安全包装器创建协程引用
    lunet_coref_create(L, ctx->co_ref);  // 调试构建下会被追踪
    
    // ……开始异步工作……
    
    return lua_yield(L, 0);
}

static void my_callback(uv_req_t *req) {
    my_ctx_t *ctx = req->data;
    
    // ……恢复协程……
    
    // 使用安全包装器释放
    lunet_coref_release(ctx->L, ctx->co_ref);  // 调试构建下会被追踪
    
    free(ctx);
}
```

### 构建验证

合并任何 C 代码更改之前：

```bash
xmake lint     # 检查命名约定（不能有 _lunet_* 泄漏）
xmake stress   # 调试构建 + 并发压力测试（必须通过）
xmake release  # 完整发布构建（先运行测试和压力测试）
```

## 调试笔记：Lua-C 栈问题

### 问题：预处理语句中的参数数量不匹配

在实现 `lunet_db_query_params` 时，出现错误：`parameter count mismatch: got 2, expected 1`

### 调试技巧

1. 在 `collect_params()` 中添加调试 fprintf 以打印 Lua 栈状态：
```c
fprintf(stderr, "DEBUG: collect_params top=%d start=%d nparams=%d\n", top, start, *nparams);
for (int i = 1; i <= top; i++) {
    fprintf(stderr, "DEBUG: stack[%d] type=%s\n", i, lua_typename(L, lua_type(L, i)));
}
```

2. 输出显示栈位置 4 处出现了意外的 `thread`：
```
DEBUG: collect_params top=4 start=3 nparams=2
DEBUG: stack[1] type=userdata
DEBUG: stack[2] type=string
DEBUG: stack[3] type=string
DEBUG: stack[4] type=thread
```

3. 追溯发现 `src/co.c` 中的 `lunet_ensure_coroutine()` 调用了 `lua_pushthread(L)`，
   但只在错误路径上弹出它，成功路径上会把 thread 遗留在栈上。

### 根本原因
`lunet_ensure_coroutine()` 第 27 行调用 `lua_pushthread(L)` 检查是否运行在
协程中，但检查通过时（非主线程情形）没有弹出该 thread。

### 修复
在 `src/co.c` 中协程检查通过后添加了 `lua_pop(L, 1)`。

### 第二个问题：互斥锁在持有状态下被销毁

修复栈问题后，发现 `db.close()` 中存在崩溃：

1. `lunet_db_close()` 锁定互斥锁
2. 调用 `lunet_sqlite_conn_destroy()`，后者销毁了互斥锁
3. 随后尝试解锁已销毁的互斥锁 → 崩溃（SIGABRT，退出码 134）

**修复：** 拆分为两个函数：
- `lunet_sqlite_conn_close()` - 关闭 SQLite 连接但保留互斥锁
- `lunet_sqlite_conn_destroy()` - 完整清理，包括互斥锁（仅由 GC 调用）

**待办：** 更详细地记录此次调试过程——这是 Lua-C 栈调试方法论的一个好例子。

## 调试方法论：内存损坏与段错误

本节记录了用于调试 lunet 运行时崩溃的工具和技术。代码库采用分层调试策略——
按成本从低到高依次使用。

### 第一层：领域追踪（fprintf 二分法）

每个模块都有由 `#ifdef LUNET_TRACE_VERBOSE` 保护的 `*_TRACE_*` 宏，
在发布构建中输出到 stderr 的成本为零。

**用法：**
```bash
xmake f -c -y --lunet_trace=y --lunet_verbose_trace=y
xmake build lunet-bin
```

然后运行复现脚本并检查 stderr。追踪日志会显示每个 socket/timer/fs/udp/signal
操作及其指针值。当日志突然中断时，崩溃就发生在最后一条打印记录与下一个操作之间。

**二分法技巧：** 如果已知崩溃发生在 A 行和 B 行之间，可在中点添加
`fprintf(stderr, ...)`，重新构建并运行，重复此过程直到定位到确切的 C 代码行。
举例：
1. 打印了 `SOCKET_TRACE_READ` → 崩溃发生在 READ 宏之后
2. 添加了 `READ_CB_RESOLVE`（在 `lua_rawgeti` 之前）和 `READ_CB_GOT_REF`
   （之后）→ `READ_CB_RESOLVE` 打印了但 `READ_CB_GOT_REF` 没有 → 崩溃发生在
   `lua_rawgeti` 内部

### 第二层：协程恢复追踪

`src/co.c` 中的 `lunet_co_resume()` 包装器有 `[CO_TRACE] RESUME` /
`[CO_TRACE] RESUMED` 打印（受 `LUNET_TRACE_VERBOSE` 保护）。这可以证明
崩溃是发生在 `lua_resume` 内部还是它之前的准备代码中。

### 第三层：地址消毒器（ASan）

ASan 对每一次内存读写进行插桩。它能捕获释放后使用（use-after-free）、
缓冲区溢出、栈溢出，并给出精确的堆栈跟踪及源代码行号。

**用法：**
```bash
xmake f -c -y -m debug --lunet_trace=y --asan=y
xmake build lunet-bin
```

`--asan` 选项会为 lunet-bin 目标添加 `-fsanitize=address
-fno-omit-frame-pointer`。检测到内存错误时，ASan 会向 stderr 打印详细报告，包括：
- 错误类型（SEGV、heap-use-after-free、heap-buffer-overflow 等）
- 精确的地址和寄存器值
- 带源文件/行号的完整堆栈回溯
- 对于 UAF：访问时的堆栈跟踪 **以及** 释放时的堆栈跟踪

**注意：** ASan 的输出会打印到 stderr，因此要检查日志文件。进程会以
`Abort trap: 6`（SIGABRT）而非 `Segmentation fault: 11` 退出。

**局限性：** ASan 链接的是系统 LuaJIT 动态库，因此 LuaJIT 内部帧可能显示为
`lua_rawgeti+0x14` 而没有源码信息。我们的 C 函数可能被内联，从而在堆栈跟踪中
缺失。寄存器值（arm64 上的 `x[0]` 到 `x[28]`）仍然有用——`x[0]` 通常是第一个
函数参数。

### 第四层：内存追踪（lunet_mem）

`lunet_mem.h` / `lunet_mem.c` 层包装了 `malloc`/`free`，提供：
- **金丝雀头**：每次分配前的魔数字节，用于检测溢出
- **释放时投毒**：释放的内存会被填充为 `0xDE` 字节，使 UAF 崩溃更明显
- **全局计数器**：在关闭时检查 `alloc_count` / `free_count` 以发现泄漏

由 `LUNET_TRACE` 启用。使用 `lunet_alloc()` / `lunet_free()` 代替原始的
`malloc` / `free`。

### 第五层：lldb / 核心转储

交互式调试：
```bash
lldb -b -o "run app/your_script.lua" -o "bt" -o "bt all" -o "quit" -- ./build/macosx/arm64/debug/lunet-run
```

在 macOS 上进行核心转储（SIP 可能会干扰）：
```bash
ulimit -c unlimited
# 运行导致崩溃的程序，然后：
lldb ./build/macosx/arm64/debug/lunet-run -c /cores/core.XXXXX
```

### 复现工具集

socket 压力测试位于 `.tmp/repro-payload/`：
```bash
LUNET_BIN="$(pwd)/build/macosx/arm64/debug/lunet-run" \
  ITERATIONS=5 REQUESTS=20 CONCURRENCY=2 WORKERS=2 \
  timeout 30 .tmp/repro-payload/scripts/repro.sh
```

日志输出到 `.tmp/repro-payload/.tmp-repro-logs/{dmz,echo,load}.log`。

### 已知陷阱

- **持有者与等待者的 `lua_State*`（lint 会检查已知的坑）**：异步句柄上下文
  按生命周期和角色命名其 `lua_State*`：`owner_L` 是长生命周期 libuv 句柄的
  持有状态（通常通过常见的回退形式由 `default_luaL()` 赋值，或从另一个
  `owner_L` 继承而来），而 `waiter_L` 是操作作用域等待者的调用状态，仅在该
  操作的生命周期内通过其 coref 有效。`xmake lint` 的规则 4/5 会拒绝旧式的
  `->L = L` / `->co = L` 模式以及直接的 `owner_L = L` / `owner_L = co` 赋值；
  更广泛的生命周期划分应视为代码评审惯例，而非已完全证明的不变量。
- **libuv 句柄相邻性**：使 libuv 句柄内存远离 `lua_State*` 等关键元数据。
  如果任何写操作越过句柄边界（ABI 不匹配、越界或收尾阶段的边界情况），
  不应损坏控制指针。建议将句柄放在结构体末尾，并/或在追踪构建中添加尾部
  金丝雀值。
- **协程 GC**：生成的协程必须通过 `lunet_co_anchor()` 锚定在 Lua 注册表中，
  否则可能在异步操作之间被垃圾回收。
- **发布版与调试版的差异**：有些 bug 只在发布构建中出现（例如，头文件中的
  `static inline` 与 `.c` 文件中的定义冲突，导致 `trace_summary` 重复定义）。
  务必同时测试 `xmake f -m release` 和 `xmake f -m debug`。

## 严格测试协议

所有智能体在验证更改或发布时必须遵守此协议。

### 1. 启用追踪构建（`LUNET_TRACE=ON`）
应用程序必须在启用零成本追踪的情况下构建和测试。这将启用：
- 协程引用计数（检测泄漏/重复释放）
- 栈完整性检查（检测污染）
- 违规时硬崩溃

```bash
xmake build-debug  # 包含 -DLUNET_TRACE=ON
```

### 2. 运行压力测试
在测试应用逻辑之前，先确保核心运行时在负载下稳定。

```bash
xmake stress
```

### 3. 应用级负载测试（RealWorld Conduit）
关于全栈负载测试（HTTP -> 路由 -> 控制器 -> 数据库 -> 协程），请使用独立的
演示应用仓库：
[https://github.com/lua-lunet/lunet-realworld-example-app](https://github.com/lua-lunet/lunet-realworld-example-app)

如果服务器在负载测试期间崩溃（退出码 > 0 或 SIGABRT），这是**严重故障**。
请检查日志中的 `[TRACE]` 断言。

## UDP 模块追踪

UDP 模块（`src/udp.c`）除了通用的协程追踪外，还有自己的领域专用追踪宏。
这些宏用于追踪网络 I/O 操作，在发布构建中零开销。

### UDP 追踪宏

| 宏 | 用途 | 输出 |
|----|------|------|
| `UDP_TRACE_BIND(handle)` | 套接字已绑定（使用 `uv_udp_getsockname` 获取实际端口） | `[UDP_TRACE] BIND #n host:port` |
| `UDP_TRACE_TX(ctx, host, port, len)` | 已发送数据报（更新全局与本地计数器） | `[UDP_TRACE] TX #n -> host:port (len bytes)` |
| `UDP_TRACE_RX(ctx, host, port, len)` | 已接收数据报（更新全局与本地计数器） | `[UDP_TRACE] RX #n <- host:port (len bytes)` |
| `UDP_TRACE_RECV_WAIT()` | 协程正在等待数据而挂起 | `[UDP_TRACE] RECV_WAIT (coroutine yielding)` |
| `UDP_TRACE_RECV_RESUME(host, port, len)` | 协程携带数据被恢复 | `[UDP_TRACE] RECV_RESUME <- host:port (len bytes)` |
| `UDP_TRACE_RECV_DELIVER(host, port, len)` | 数据从队列中立即被投递 | `[UDP_TRACE] RECV_DELIVER (immediate) <- host:port (len bytes)` |
| `UDP_TRACE_CLOSE(ctx)` | 套接字已关闭（输出本地统计信息） | `[UDP_TRACE] CLOSE (local: tx=n rx=n) (global: ...)` |

### 计数器

这些宏在 `src/udp.c` 中维护**静态（文件作用域）计数器**：
- `udp_trace_bind_count` - 已绑定套接字总数
- `udp_trace_tx_count` - 已发送数据报总数
- `udp_trace_rx_count` - 已接收数据报总数

每个套接字的计数器（`trace_tx`、`trace_rx`）存储在 `udp_ctx_t` 中
（受 `LUNET_TRACE` 保护）。

### 关闭汇总

应用程序退出时（调试构建中），会调用 `lunet_udp_trace_summary()`：
`[UDP_TRACE] SUMMARY: binds=n tx=n rx=n`

### 使用模式

添加新的 UDP 操作时：

1. 在关键点添加 `UDP_TRACE_*` 调用（地址解析之后、I/O 前后）
2. 使用 `xmake build-debug` 构建以启用追踪
3. 运行测试脚本并检查 stderr 中的 `[UDP_TRACE]` 行
4. 验证计数是否平衡（例如，回显服务器应满足 tx == rx）

### 示例输出

```
[UDP_TRACE] BIND #1 127.0.0.1:20001
[UDP_TRACE] RECV_WAIT (coroutine yielding)
[UDP_TRACE] RX #1 <- 127.0.0.1:54321 (64 bytes)
[UDP_TRACE] RECV_RESUME <- 127.0.0.1:54321 (64 bytes)
[UDP_TRACE] TX #1 -> 127.0.0.1:20002 (72 bytes)
[UDP_TRACE] CLOSE (tx=1 rx=1)
```
</content>
