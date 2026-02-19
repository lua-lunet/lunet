# EasyMem 集成与性能分析报告

## 范围

本报告取代了之前的内存安全策略文档，记录了 Lunet 中当前的 EasyMem 集成情况：

- `xmake.lua` 中的可选 EasyMem 附加支持
- 在追踪和 ASAN 构建中自动启用 EasyMem
- 早期实验阶段的集成/性能分析记录
- 示例/演示运行的性能分析输出

## 新增的构建/分析模式

Lunet 现在支持以下 EasyMem 路径：

1. **在追踪构建中自动启用**
   - `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y`
2. **在 ASAN 构建中自动启用**
   - `xmake f -c -m debug --lunet_trace=y --asan=y -y`
   - Windows 在工具链支持时使用 `/fsanitize=address`。
3. **手动选择启用（开发档位）**
   - `xmake f -c -m debug --lunet_trace=n --lunet_verbose_trace=n --easy_memory=y -y`

## 验证运行

日志存档位置：

- `.tmp/logs/20260214_054129/`
- `.tmp/logs/20260214_061022/`（零开销审计）
- `.tmp/logs/20260214_061820/`（迁移后扩展分配器构建/运行验证）

### 构建验证

| 配置 | 结果 | 备注 |
|------|------|------|
| Debug + 追踪 | 通过 | EasyMem 已下载并启用 |
| Debug + ASAN | 通过 | 确认 `-fsanitize=address` + `LUNET_EASY_MEMORY_DIAGNOSTICS` |

### 示例/演示验证

| 脚本 | 结果 | 关键观察 |
|------|------|----------|
| `examples/03_db_sqlite3.lua` | 通过 | 功能性数据库流程通过；打印了 EasyMem 摘要 + ASCII 可视化 |
| `examples/06_paxe_encryption.lua` | 通过 | PAXE 加密/解密流程通过；打印了 EasyMem 摘要 + 可视化 |
| `examples/07_paxe_stress.lua`（`ITERATIONS=200`） | 通过 | 吞吐量输出稳定；脚本通过 `os.exit` 结束，因此跳过了 Lunet 关闭摘要 |
| `test/stress_test.lua`（`5x10`）debug+ASAN | 通过 | `[MEM_TRACE] allocs=53 frees=53 peak=3456`，追踪摘要平衡，无 ASAN 错误 |

## 分析发现

1. **EasyMem 诊断已激活**
   - 在启用诊断的配置中，`print_em()` 和 `print_fancy()` 输出在关闭时正常显示。
   - ASCII 内存可视化（"图表"）按预期输出。

2. **分配器统计对 Lunet 核心分配是准确的**
   - 压力运行显示分配/释放计数平衡且峰值稳定较低。

3. **扩展分配的源码迁移已完成**
   - 在以下文件中，直接的 `malloc/calloc/realloc/free/strdup` 调用已替换为 Lunet 分配器包装器：
     - `ext/sqlite3/sqlite3.c`
     - `ext/mysql/mysql.c`
     - `ext/postgres/postgres.c`
     - `src/paxe.c`
   - 所有相关目标的构建验证已通过：`lunet-sqlite3`、`lunet-mysql`、`lunet-postgres`、`lunet-paxe`。
   - 注意：模块驱动示例的顶层 `lunet-run` 内存摘要仍可能显示 `allocs=0`，因为驱动模块目前编译了各自的核心分配器状态副本；这需要后续的共享核心链接来聚合到一个全局状态。

4. **ASAN + EasyMem 双重覆盖可正常工作**
   - ASAN 检测和 EasyMem 诊断在调试构建中同时激活。
   - 在执行的压力路径中未观察到清洁器故障。

## 进一步利用 EasyMem 功能的建议

为充分利用 EasyMem（特别是在数据库工作线程/互斥锁路径方面），建议接下来采取以下措施：

1. **统一跨模块边界的分配器状态**
   - 当前驱动模块嵌入了核心源码，因此分配器计数器是按模块独立的。
   - 为实现完全统一的分析/完整性报告，需要重构为共享一个分配器状态（例如，让驱动模块链接到共享的核心分配器/运行时对象，而不是在每个模块目标中复制 `src/lunet_mem.c`）。

2. **为数据库工作任务提供按操作的内存区**
   - 为每个 `uv_queue_work` 数据库操作创建嵌套/临时 EasyMem 作用域。
   - 在完成边界（`after_work` 回调）释放该作用域，在 uv 互斥锁保护的操作间保持内存中性。

3. **驱动本地内存区策略**
   - 将长生命周期的连接结构保留在稳定的根内存区中。
   - 将查询/结果临时缓冲区放置在嵌套/临时内存区中，以减少碎片化并简化提前错误路径的清理。

4. **CI 诊断产物**
   - 从 trace+ASAN CI 运行中捕获 EasyMem 摘要/可视化作为产物。
   - 添加回归阈值（例如，每个压力场景的峰值使用量偏移）。

## 结论

EasyMem 现已作为可选的分配器后端集成，并在追踪/ASAN 模式下自动激活。数据库/PAXE 代码路径中的扩展分配调用已迁移到 Lunet 分配器包装器。剩余工作是统一跨共享模块边界的分配器状态，使所有模块分配出现在一个合并的运行时摘要中。

## 零开销验证（发布版，EasyMem 禁用）

审计日志集：`.tmp/logs/20260214_061022/`

### 使用的方法

对比了三种配置下的发布产物：

1. 默认发布版（`--lunet_trace=n --lunet_verbose_trace=n`）
2. 显式禁用 EasyMem 的发布版（`--easy_memory=n --asan=n`）
3. 历史 EasyMem 启用发布产物（遗留基准）

对每种配置，捕获了：
- `lunet-run` 和 `lunet.so` 的 `sha256sum`
- 文件字节大小（`wc -c`）
- 段大小（`size`，text/data/bss）
- 动态符号计数（`nm -D --defined-only`）
- 动态依赖（`readelf -d` NEEDED 条目）

### 结果

默认发布版和显式禁用 EasyMem 的发布版**逐字节完全相同**：
- `lunet-run` 哈希：`7d7c248d32dfa132a84e850dadafca030c1d75814ba325298c45641f3a7a930b`
- `lunet.so` 哈希：`ad16fe0cccad4eb41ef7bbc50f21234f6c7b0d9ba44f6d50c7f5d959362125e7`
- 大小/段/依赖相同
- 未检测到 EasyMem 字符串/符号特征

这确认了禁用 EasyMem 时**零意外发布开销**。

## 启用追踪/诊断时的顶层产物统计

基线（发布版，EasyMem 禁用）：
- `lunet-run`：47,248 字节
- `lunet.so`：47,968 字节

历史 EasyMem 启用发布产物（遗留基准）：
- `lunet-run`：59,536 字节（**+12,288**，+26.01%）
- `lunet.so`：60,384 字节（**+12,416**，+25.88%）
- 新增导出分配器符号族（`em_*`）

历史实验诊断配置（现已移除）：
- `lunet-run`：67,728 字节（**+20,480**，+43.35%）
- `lunet.so`：68,608 字节（**+20,640**，+43.03%）
- 新增诊断符号/输出路径，包括 `print_em` 和 `print_fancy`

在本次审计中，任何变体均未引入额外的共享库依赖（Linux 上仍为 `libluajit-5.1`、`libuv`、`libc`）。
