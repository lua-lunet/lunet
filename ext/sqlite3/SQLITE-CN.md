# `lunet.sqlite3`

SQLite 驱动。可以直接 `require("lunet.sqlite3")` 发布压缩包中的预构建模块
（`lunet/sqlite3.lua` + `lunet/sqlite3core.so`；压缩包布局见
[docs/RELEASE-LAYOUT-CN.md](../docs/RELEASE-LAYOUT-CN.md)），也可以自己用
`xmake build lunet-sqlite3` 构建。本页是完整参考：API、句柄生命周期，以及
性能模型——这个形状背后的*为什么*。

占位符为 `?`。参数通过 `sqlite3_bind_*` 原生绑定，值永远不会被拼接进 SQL。
本项目有意不提供 `db.escape`。

> ## 使用只读连接前必读
>
> 在某些负载下，以 WAL 模式打开并把读交给只读连接（它**没有后台线程**，
> 因此**有可能拖住主循环**）确实能拿到峰值性能。这笔交易是否成立，完全取
> 决于你的负载和你链接的 SQLite 版本；注意事项很多。**依赖它之前，请先读
> 懂 [SQLite 文档](https://sqlite.org/wal.html)。** 设置想设的任何参数——
> 什么会生效取决于你的负载。
>
> **有疑问就不要用只读连接，全部走读写连接。** 如果它停摆、阻塞或行为不
> 符预期，那是没有读本警告的问题——驱动做的事与本文所写完全一致，不多不
> 少。这里没有任何魔法。

## 表面

| 函数 | 说明 |
|---|---|
| `open(config)` | `{ path = "app.db" }`，可选 `create = "WAL"\|"NORMAL"` 与透传设置（`busy_timeout` 毫秒、`foreign_keys` 布尔、`synchronous` "OFF"\|"NORMAL"\|"FULL"） |
| `close(conn)` | 关闭单个句柄 |
| `query(conn, sql, ...)` | 返回行表数组 |
| `exec(conn, sql, ...)` | 返回 `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | 与上述行为一致 |
| `prepare(conn, sql)` | 可复用的预处理语句；`stmt:query` / `stmt:exec` / `stmt:close`——见[预处理语句](#预处理语句prepared-statements) |

职责的拆分：二进制模块（`lunet.sqlite3core`）只管异步 I/O——一次 worker 跳
的 open 返回 `(rw, ro, err)`，`rw` 上的语句派发到 uv worker 池，`ro` 上的语

所有调用必须在 `lunet.spawn` 出的协程里。

## open 契约

```lua
local db = require("lunet.sqlite3")

-- 1. 已由部署方准备好的既有数据库文件。驱动以读写方式打开它，且绝不
--    更改其日志模式。文件缺失是响亮的错误——准备（建文件、设 WAL）是
--    部署侧的动作：
--      sqlite3 app.db "PRAGMA journal_mode=WAL;"
local rw, ro, err = db.open({ path = "app.db" })

-- 2. 让驱动来建文件——模式在创建时声明：
local rw, ro, err = db.open({ path = "app.db", create = "WAL" })
--    create = "WAL"    -> 建文件并设 journal_mode=WAL（检查 pragma 的返回
--                         值；文件系统承载不了 WAL 时 open 响亮失败）。
--    create = "NORMAL" -> 建文件，日志模式保持 SQLite 默认（回滚日志）。
--    不存在"取消 WAL"：WAL 对文件是持久的，驱动绝不会擅自更改既有文件
--    的模式。对既有文件传 create=WAL 会重发该 pragma（幂等）；
--    create=NORMAL 则对模式不做任何事。

-- 3. 知情用户的透传设置，作用于 open 时的两个连接：
local rw, ro, err = db.open({
    path = "app.db", create = "WAL",
    busy_timeout = 3000,        -- 毫秒：每个连接的 busy handler
    foreign_keys = true,        -- PRAGMA foreign_keys（厂商默认关）
    synchronous  = "NORMAL",    -- 持久性权衡；绝不是驱动默认值
})

-- 4. 单元测试：把路径换成 :memory:，同样的代码形状照跑。
--    驱动返回一个连接充当两个句柄；create= 被忽略；那里的 ro 不强制
--    只读。每次 open 都是全新私有数据库。
local rw, ro, err = db.open({ path = ":memory:" })
```

透传设置是每连接、后写者赢——open 之后可以独立调整任一句柄：

```lua
db.exec(rw, "PRAGMA busy_timeout = 5000")  -- 只改 rw；ro 保持 open 时的值
```

## 读与写

`open` 返回两个连接：

```lua
local db = require("lunet.sqlite3")

lunet.spawn(function()
  local rw, ro, err = db.open({ path = "app.db", create = "WAL" })
  if not rw then error(err) end

  -- 写入走 rw（照旧进入 worker 池）……
  assert(db.exec(rw, "INSERT INTO t VALUES (?)", 1))

  -- ……读取走 ro：在读句柄上语句在循环线程内联执行——
  -- 不经过 worker，不发生 yield。
  local rows = assert(db.query(ro, "SELECT * FROM t"))

  db.close(rw)
  db.close(ro)
end)
```

- `rw` —— 读写连接：单专用 worker、语句派发到 uv worker 池。它也
  能读：它就是那个通用连接，而且是唯一能写的。
- `ro` —— 以 `SQLITE_OPEN_READONLY` 打开的第二个连接，用于读流量。**其上
  的 `query`/`exec` 在循环线程内联执行——没有后台线程，也不发生 yield。**
  WAL 模式下读者与写者互不阻塞，因此循环线程路径就是快路径；代价是重读
  （大扫描、冷页缓存）会让所有协程、socket 和定时器停摆其执行时长。如果
  不想要内联读句柄，按约定丢弃它——`local rw, _ = db.open({ path =
  "app.db" })`（`_` 只是 Lua 惯例，不是语言特性；ro 连接仍存在，直到
  丢弃即可）。
- **失败形态：** 打开失败时两个句柄均为 `nil`，错误是第三个返回值 ——
  `local rw, ro, err = db.open(...)`。这是 sqlite3 驱动特有的形态：网络驱动
  仍保持 `(conn, err)`。
- **句柄生命周期：** 句柄逐个经 `close` 关闭。
- 忽略 `ro`、只使用 `rw` 的消费者，行为与从前的单连接一致。
- **路由是消费者在构建期拥有的正确性。** 没有读写语句标记，也没有派发机制。
  误路由到 `ro` 的写语句在 `prepare` 阶段成功（廉价解析，不加锁），在 `step`
  阶段响亮失败并返回 `SQLITE_READONLY`（"attempt to write a readonly
  database"）——绝不可能静默提交。`sqlite3_db_readonly(ro, "main")` 仍在底层
  可用，供测试把不变量当一等断言使用。
- **快照：** `ro` 上的读看到的是读开始那一刻的已提交状态。同一瞬间的
  写后读在 `ro` 上是旧的；一致性关键的读走 `rw`（每次调用都是全新的读事
  务，写调用返回之后发出的读必然是新的）。

## 性能模型

对一个固定 API、以 SQLite 为后端的 HTTP 服务所做的性能调优 ——
[lua-lunet/twelve-dollar-server-challenge](https://github.com/lua-lunet/twelve-dollar-server-challenge)
—— 得出了最优配置的形状，而本驱动就是那个形状：

- **读写分离。** 一个连接独占写入；只读连接服务读流量。WAL 模式下读者与唯
  一的写者互不阻塞，两条路径从不互相等待。
- **写入走单线程。** SQLite 同一时刻只允许一个写者；更多的写连接买不到任
  何东西，只会增加争用。
- **只读连接上的并发读，在循环线程上执行。** 在 `SQLITE_OPEN_READONLY`
  连接上做读是纯粹针对页缓存的 CPU 工作：把它内联执行——不经 worker 池、
  不 yield、不跨线程交接——消除了读路径上最大的每请求开销。在那次调优中，
  负载带内拆分方案的 p95 比把所有语句都挤进单个池化句柄快约 4 倍，且每种
  配置下 `SQLITE_BUSY` 事件为零。

要避免的失败模式：反过来的路由——把读多写少的负载全压到 `rw` 连接上——可
能是次优的：每个读都要付出 worker 池的代价和跨线程交接，而且读要在同一连接
上排在写后面。如果你发现延迟不理想，先检查读走的是哪个句柄。

本驱动**有意不提供池化**。单写路径就是设计本身：想更快，就把读交给 `ro`
——永远不要靠加宽池。

## 事务

使用 `lunet.sqlite3_tx`（`sqlite3_tx.lua`，与二进制一同发布）。
事务请放在 `rw` 句柄上。

```lua
local sqlite = require("lunet.sqlite3")
local tx = require("lunet.sqlite3_tx")

local ok, err = tx.transaction(rw, function(t)
    t.exec("DELETE FROM nodes WHERE path = ?", dst)
    local r = t.exec("UPDATE nodes SET path=? WHERE path=? AND version=?",
                     dst, src, version)
    if r.affected_rows == 0 then return nil, "version conflict" end
    return true
end, "IMMEDIATE")

if not ok and err.poisoned then db.close(rw) end
```

返回非 nil 值即提交；返回 `nil, reason` 或抛出错误则回滚。完整约定见
`sqlite3_tx.lua` 的头部注释。

**最关键的规则：** 事务属于**连接**，而不属于协程。若连接池在每次调用后都把句柄
归还，`BEGIN`、工作语句与 `COMMIT` 会落在不同句柄上，最终什么也没提交。
`transaction()` 在整个工作单元期间持有同一个句柄——这正是它接收 `conn` 而不是
配置表的原因。

### 驱动特有事实

- **任何涉及写入的场景都请传 `"IMMEDIATE"`。** 第三个参数是加锁模式。SQLite 默认
  的 `DEFERRED` 在首条语句之前不加锁，因此另一个写者可能先抢到写锁，导致你的
  `UPDATE` 在 `BEGIN` **已经成功之后**才以 `SQLITE_BUSY` 失败。`IMMEDIATE` 把这个
  失败提前。`EXCLUSIVE` 还会阻塞读者。
- 与 Postgres 不同，语句错误不会污染会话——SQLite 允许你在 `fn` 内捕获 `t.*` 的
  错误后继续。这通常仍是错的，但不会导致后续语句全部失败。
- **`query`/`exec` 会绑定参数。** 在 2026-07-25 之前并非如此：只有
  `query_params`/`exec_params` 调用了 `collect_params`，因此
  `db.exec(conn, "INSERT INTO t VALUES (?,?)", a, b)` 会让两个占位符都未绑定
  （即 `NULL`）却报告成功。如果你改动 `sqlite3.c` 中的 `lunet_db_query` 或
  `lunet_db_exec`，请保留 `collect_params` 调用——此处的回归是静默的数据丢失，
  而不是崩溃。
- **读写拆分需要文件路径。** 对 `":memory:"` 以 `SQLITE_OPEN_READONLY` 再开的
  第二个连接是一个全新、空、私有的数据库——不是写者数据的读者。打算使用
  `ro` 时请传文件路径；在 `:memory:` 上只用 `rw` 即可。

## 预处理语句（Prepared statements）

`prepare` 让厂商语句跨调用存活，而不是每次调用都重新解析加规划：SQL 只编译
一次（`sqlite3_prepare_v2`），之后每次调用重置、重新绑定并步进。

```lua
local stmt, err = db.prepare(rw, "SELECT name FROM users WHERE age > ?")
if not stmt then error(err) end

local rows, qerr = stmt:query(30)   -- 绑定语义与 query 一致
local res, eerr  = stmt:exec(...)   -- 用于 INSERT/UPDATE/DELETE
stmt:close()                        -- 立即 finalize，或交给 GC
```

- `stmt:query(...)` / `stmt:exec(...)` 每次调用都重新绑定变参，语义与
  `query` / `exec` 完全一致；每次调用在绑定前先执行 `sqlite3_reset` 加
  `sqlite3_clear_bindings`，并让语句保持就绪供下次调用。
- **一条语句绑定一个连接。** 在读写句柄上准备的语句与该句柄的其他语句一样
   进入 worker 池；在只读句柄上准备的语句内联执行，与该句柄的语义一致。
- **只读句柄上的写 SQL 会在 prepare 阶段就被大声拒绝**——比误路由的普通
  exec 在步进阶段才失败要早得多。
- `stmt:close()` finalize 厂商语句；之后使用会大声报错。未 `close` 就丢弃的
  语句由 finalizer 兜底 finalize。
- 连接关闭时其上仍然打开的语句是安全的：所有打开的语句都随之 finalize，
  每个幸存的语句 userdata 之后使用时大声报错。
- 本驱动不存在 `pool_size` 问题：它没有池。

值得吗？对一条无关紧要的语句，每次调用的准备成本测不出来；对复杂或高频率
的语句则可能值得。阅读 SQLite 文档，按你自己的负载决定——这里没有魔法。
小应用中该 API 的形态见 `examples/10_db_prepared.lua`。

## 固定连接（pinning）是如何被验证的

SQLite 不需要服务器，因此这一项**是**提交进仓库的测试：
`test/smoke_sqlite3_tx.lua`（21 项检查）。在
`xmake build lunet-sqlite3 && xmake build-release` 之后用
`lunet-run test/smoke_sqlite3_tx.lua` 运行。

真正值得保留的方法论——与 postgres、mysql 驱动的人工验证一致（见各自的 README）：

1. 覆盖两种结果与两条中止路径：提交、abort-by-nil、在 `fn` 内抛出错误、以及在
   `fn` 内制造语句错误。每条中止路径都必须让事务前的状态保持原样。
2. 在事务内断言 `t.exec` 返回的 `affected_rows`——那是 compare-and-set 的信号，
   而 `t.query` 不会报告它。
3. 在干净回滚后断言 `err.poisoned == false`，并证明连接随后仍然可用。
4. 覆盖各项防护：非法加锁模式、nil 连接、非函数的事务体。
5. 由于 SQLite 是单文件的，这里没有 postgres/mysql 那样的第二会话 observer。这是
   本测试**无法**展示的一点，因此请把 postgres 那一轮当作隔离性的真正证明，而把
   本测试当作包装器控制流的证明。

最近一次运行：全部 21 项检查通过（2026-07-25）。
