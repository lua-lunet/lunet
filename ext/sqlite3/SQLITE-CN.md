# `lunet.sqlite3`

SQLite 驱动。可以直接 `require("lunet.sqlite3")` 使用发布包里预构建的模块（`lunet/sqlite3.lua` + `lunet/sqlite3core.so`；归档布局见 [docs/RELEASE-LAYOUT-CN.md](../docs/RELEASE-LAYOUT-CN.md)），也可以用 `xmake build lunet-sqlite3` 自行构建。本页是完整参考：API、两条所有权路径、open 契约与性能模型。

占位符是 `?`。参数通过 `sqlite3_bind_*` 原生绑定，值永远不会拼接进 SQL。因此没有 `db.escape`。

## 所有权与路由

驱动有两条逻辑路径，各自只有一个所有者，应用决定工作放在哪条上：

- **`ro` 归 Lunet 的单事件循环线程所有。** `query_ro(ro, sql, ...)` 同步、内联、不发生 yield。在这次调用进行期间，循环不可能同时执行另一个 `ro` 调用：其他协程只有等控制权交还调度器才会执行，在飞的多条请求绝不意味着这条连接上同时有两个 SQLite 调用在跑。每次调用都是*临时语句*：prepare、bind、step、收集、finalize——什么都不缓存。`ro` 只用于短、可测量的点读；重读会让循环在其执行期间停摆。这条路径刻意没有命名语句缓存，也没有语句池。
- **`rw` 归一个专用后台 worker 线程所有。** 它处理写，以及对事件循环来说太重、应当在 SQLite 执行期间让出循环的读。调用 `rw` 会暂停调用协程；worker 完成操作后，运行时带着结果恢复该协程。整条 `rw` 连接上的工作按 FIFO 派发顺序串行执行。`rw` 连接只有一条，属主 worker 只有一个——没有连接池，也没有语句池。

路由是显式的，绝不从 SQL 前缀推断：

| 调用 | 连接 | 运行位置 |
|---|---|---|
| `query_ro(ro, sql, ...)` | `ro` | 事件循环线程内联 |
| `query(rw, sql, ...)` | `rw` | 专用 worker，yield |
| `exec(rw, sql, ...)` | `rw` | 专用 worker，yield |
| `query_params` / `exec_params` | `rw` | 专用 worker，yield |
| `prepare(rw, sql)` | `rw` | 专用 worker，yield |

`rw` 同时也是通用连接——它也读。路由调用有警卫：用 `ro` 句柄调用
`query`、`query_params`、`exec`、`exec_params` 与 `prepare` 会响亮地失败，
返回一个路由错误表（`op` 为 `"route"`，消息指向 `query_ro`）——路由契约
就是 API 本身，不是提示。而*经 `query_ro` 把写语句发往文件 `ro` 句柄*
——真正在 `ro` 连接上运行的调用——则由 SQLite 自身在 step 阶段以其只读
错误拒绝（`code = 8`，`SQLITE_READONLY`），绝不可能静默提交。`ro` 上的
读看到的是读开始那一刻的已提交状态；一致性关键的读走 `rw`（那里每次
调用都是一次全新读，且在写调用返回之后发出，所以是最新的）。

SQLite 的互斥锁模式不建立 FIFO 调度，它替代不了这份所有权契约：它只决定 SQLite 如何与其自身的锁竞争。见 [互斥锁模式](#mutex-模式)。

## Surface

| 函数 | 说明 |
|---|---|
| `open(config)` | 原始驱动 open；见 [open 契约](#open-契约)。成功返回 `(rw, ro, nil)`，失败 `(nil, nil, err)` |
| `connect(path, opts)` | 可选的封装 helper：`synchronous = "NORMAL"` 默认值，调用方选项覆盖；见 [helper](#helper) |
| `close(conn)` | `rw`：先排空已受理的工作，再关闭；`ro`：内联关闭 |
| `query_ro(conn, sql, ...)` | 在 `ro` 上内联执行；每次调用一条临时语句 |
| `query(conn, sql, ...)` | 返回行集，在 `rw` 上——写语句带 `RETURNING` 也用它 |
| `exec(conn, sql, ...)` | `{ affected_rows, last_insert_id }`，在 `rw` 上 |
| `query_params` / `exec_params` | 与上两个相同，但用显式绑定列表 |
| `prepare(conn, sql)` | 供启动清单使用的命名语句；yield。`stmt:query` / `stmt:exec` / `stmt:close` ——见 [命名语句](#命名语句) |

错误是 Lua 表——见 [错误](#错误)。

所有调用都必须在用 `lunet.spawn` 派生的协程里执行。

## open 契约

```lua
local db = require("lunet.sqlite3")

-- 1. 已存在、已预留的数据库文件。驱动以读写方式打开，且绝不碰它的日志模式。
--    文件不存在是响亮的错误——预留（创建文件、设定 WAL）是部署动作：
--      sqlite3 app.db "PRAGMA journal_mode=WAL;"
local rw, ro, err = db.open({ path = "app.db" })

-- 2. 让驱动创建文件——模式在创建时声明：
local rw, ro, err = db.open({ path = "app.db", create = "WAL" })
--    create = "WAL"    -> 创建文件、请求 WAL，并验证 SQLite 确实返回了 WAL
--                         （无法承载 WAL 的文件系统会让 open 响亮失败）。
--    create = "NORMAL" -> 创建文件，日志模式保持在 SQLite 默认值。
--    create 省略       -> 文件必须已存在，且其日志模式不被改动。
--    这里没有"撤销 WAL"：WAL 对文件是持久的，驱动绝不擅自改动既有文件的模式。
--    对既有文件 create=WAL 会重新发出该 pragma（幂等）。

-- 3. 透传项，应用到各自相关的连接上：
local rw, ro, err = db.open({
    path = "app.db", create = "WAL",
    busy_timeout = 3000,        -- 毫秒：每个连接上的 busy handler
    foreign_keys = true,        -- PRAGMA foreign_keys
    synchronous  = "NORMAL",    -- 持久性取舍；见下面的 helper
})

-- 4. 单元测试：把 path 换成 :memory:，同样的代码形状就能跑。
--    两条逻辑路径共用一个物理连接，访问经其所有者（rw worker）串行化。
--    那里 ro 不强制只读——:memory: 是测试替身，不是文件级只读保证。
local rw, ro, err = db.open({ path = ":memory:" })
```

```lua
-- 5. 显式互斥锁模式（可选；默认不变）：
local rw, ro, err = db.open({ path = "app.db", mutex = "nomutex" })
```

### mutex 模式

`mutex` 选择打开的连接所用的线程模式：

- 省略：SQLite 的编译配置默认——通常是 serialized 模式。什么都不变。
- `mutex = "nomutex"`：SQLite 的 multi-thread 模式。这是**显式选择，声明调用方遵守单所有者、无非并发使用的契约**——在本驱动的所有权模型下（循环线程一个 `ro`，worker 一个 `rw`），每条连接同一时刻恰好只有一个属主，逐条调用中的互斥锁纯属开销。除非你确定要，否则保持默认。
- `mutex = "fullmutex"`：SQLite 的 fully-serialized 模式，显式指定。

互斥锁模式在打开时逐连接设置（`SQLITE_OPEN_NOMUTEX` / `SQLITE_OPEN_FULLMUTEX` 打开标志）；驱动绝不会替嵌入式运行时翻转进程级 SQLite 配置。

### 未知选项

未知选项名与非法值都会清晰明了地失败——它们是响亮的错误，绝不会被静默忽略。接受的选项集是：`path`、`create`、`busy_timeout`、`foreign_keys`、`synchronous`、`mutex`。

失败的 open 不返回任何可用的一半句柄对，并释放它打开过的一切：两个句柄都是 `nil`，错误是第三个返回值。

### helper

```lua
local db = assert(require("lunet.sqlite3"))
local rw, ro, err = db.connect("app.db", { create = "WAL" })
```

`connect(path, opts)` 是面向应用的 `open` 封装：它从 `synchronous = "NORMAL"` 出发，然后把调用方选项复制覆盖到默认值上——调用方的显式值优先，其他受支持的选项原样透传。原始 `open` 绝不会取得 helper 的默认值；想要别的设置的驱动都是显式选择。

透传项是逐连接的、以最后一次写为准——open 之后可以独立微调任一受控句柄：

```lua
db.exec(rw, "PRAGMA busy_timeout = 5000")  -- 只影响 rw；ro 保持 open 时的值
```

## 读与写

```lua
local db = require("lunet.sqlite3")

lunet.spawn(function()
  local rw, ro, err = db.open({ path = "app.db", create = "WAL" })
  if not rw then error(err.message) end

  -- 写走 rw（专用 worker）……
  assert(db.exec(rw, "INSERT INTO t VALUES (?)", 1))

  -- ……短的点读走 ro：在循环线程内联，不 yield，每次调用一条临时语句。
  local rows = assert(db.query_ro(ro, "SELECT * FROM t"))

  db.close(rw)   -- 排空已受理的 rw 工作，然后关闭
  db.close(ro)
end)
```

- `rw` ——读写连接：一个专用后台 worker 线程，FIFO 派发。它也是通用连接，也是唯一能写的。
- `ro` ——以 `SQLITE_OPEN_READONLY` 打开的第二个连接，用于点读。若不想用它，`local rw, _ = db.open({ path = "app.db" })`（`_` 是 Lua 惯例，不是语言特性），所有调用都落在 `rw` 上。

## 命名语句

`prepare` 保持厂商语句存活，而不是逐调用编译：SQL 由 worker 一次性编译（`sqlite3_prepare_v2`），每次调用重置、重新绑定、步进。

```lua
local stmt, err = db.prepare(rw, "SELECT name FROM users WHERE age > ?")
if not stmt then error(err.message) end

local rows, qerr = stmt:query(30)   -- 绑定语义与 query 相同
local res, eerr  = stmt:exec(...)   -- INSERT/UPDATE/DELETE 用这个
stmt:close()                        -- 现在在属主上 finalize；或交给 GC
```

命名语句以一次**启动清单**的方式声明：应用在开始服务请求之前在 `rw` 连接上准备好它们，每条语句终身绑定该连接。

- 每次调用在派发前对参数做快照；worker 在属主上执行该快照，然后在下一条排队调用开始前重置语句。
- **同一语句的并发调用者按次序等待，各自拿回各自的结果。** 普通的并发使用绝不产生语句级 busy 错误——FIFO 队列就是调度，不是 SQLite 锁。

## 错误

错误是 Lua 表，保留 SQLite 的消息、主码与扩展码以及操作上下文：

```lua
rows, err = db.query_ro(ro, "SELECT * FROM nope")
-- err = {
--   message       = "no such table: nope",   -- sqlite3_errmsg()
--   code          = 1,                        -- 主码 (SQLITE_ERROR)
--   extended_code = 1,                        -- sqlite3_extended_errcode()
--   op            = "query_ro",               -- 操作上下文
-- }
```

SQLite 产生的错误携带 `code` 与 `extended_code`（否则只有 `message` 与 `op`——比如路由违规或连接已关闭）。请读 `err.message`，别用 `tostring(err)`。

关键情形：

- *经 `query_ro` 发往文件 `ro` 句柄的写*在 step 阶段收到 SQLite 的只读
  错误（`code = 8`，`SQLITE_READONLY`，`extended_code` 在场）。其余调用
  （query/params/exec/prepare）用 `ro` 句柄调用则得到路由违例
  （`op = "route"`）——路由由调用决定，错误的调用根本不会到达 SQLite。
- 语句失败是**给调用者的结果，绝不是 worker 关机**：连接保持可用，失败之后的下一次调用照常成功。
- 启动清单里的 `prepare` 失败返回 `(nil, err)`——释放句柄对，修好清单再开始服务。

## 事务

使用 `lunet.sqlite3_tx`（`sqlite3_tx.lua`，与二进制一起发布）。事务放在 `rw` 句柄上。

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

返回非 nil 提交；返回 `nil, reason` 或抛错则回滚。完整契约见 `sqlite3_tx.lua` 的头注释。

**要紧的一条规则：** 事务属于*连接*，不属于协程。逐调用签出、用完归还的连接池会把 `BEGIN`、工作与 `COMMIT` 摊到不同句柄上，最终什么也提交不了。`transaction()` 在整个单元内持有一个句柄——这正是它接收 `conn` 而非配置的原因。

### 驱动特有事实

- **凡是要写的，都传 `"IMMEDIATE"`。** 第三个参数是锁模式。SQLite 默认的 `DEFERRED` 直到第一条语句才取锁，别的写者可能抢先拿到写锁，于是 `BEGIN` 成功之后你的 `UPDATE` 一样会以 `SQLITE_BUSY` 失败。`IMMEDIATE` 把这个失败提前暴露。`EXCLUSIVE` 连读者也挡住。
- 不同于 Postgres，语句错误不会毒化会话——SQLite 允许你在 `fn` 里捕获 `t.*` 错误并继续。通常仍是错的，但不会让之后的每条语句都失败。
- **`query`/`exec` 绑定参数。** `db.exec(rw, "INSERT INTO t VALUES (?,?)", a, b)` 绑定 `a`、`b`，与 `exec_params` 相同。
- **路由拆分需要文件路径。** `:memory:` 无法拆分：两条逻辑路径在那里别名同一个物理连接，访问经其所有者（`rw` worker）串行化。打算用内联 `ro` 路径就传文件路径；在 `:memory:` 上只用 `rw`。

## 值

绑定：`nil` → NULL，数字 → integer 或 double（可精确表示整数按整数绑定），布尔 → 0/1，字符串 → text。列按逐个单元格保留 SQLite 产出的类型：`NULL` 读作 Lua `nil`，整数读作 Lua 数字，实数读作 Lua 数字，text 读作 Lua 字符串，blob 读作承载精确字节的 Lua 字符串（保长，包含内嵌 NUL）。逐单元格的 SQLite 类型驱动转换——同一列跨行类型不同也能逐行正确读出。

## 生命周期与拆除

应用在其生命周期内持有打开的句柄对，并于拆除时关闭。不存在进程级、按路径为键的连接缓存：开两次就是两个独立句柄对，关闭其一不影响另一个。

- `close(rw)` 等待已受理的 `rw` 工作排空（FIFO——close 排在其后排队），在属主上 finalize 清单中的每条语句，然后关闭一次物理连接。之后任何使用都会大声失败。
- `close(ro)` 内联关闭。
- 未 `stmt:close()` 就丢弃的语句由 GC 回收时 finalize；关闭连接会一并 finalize 其上所有仍然打开的语句。

## 性能模型

对一个固定 API 的 SQLite 后端 HTTP 服务做的性能调优——
[lua-lunet/twelve-dollar-server-challenge](https://github.com/lua-lunet/twelve-dollar-server-challenge)
——给出了最优形态，本驱动就是这个形态：

- **读写分离。** 一条连接持有写；只读连接服务点读。WAL 模式下读者与单个写者永不冲突，两条路径互不阻塞。
- **写只用一条线程。** SQLite 同一时间只允许一个写者；更多写连接买不到任何东西，只添竞争。
- **短读在循环线程内联。** 提交方案实测了短内联读的逐调用临时 prepare 并予以保留：一个快速点读只在自身执行期间占用事件循环，没有 worker 跳转、没有 yield、没有跨线程交接。那次调优里，该拆分在整个负载区间测得比"所有语句都过单个池化句柄"好约 4 倍的 p95，且所有配置下 `SQLITE_BUSY` 事件数为零。
- **重活下循环。** 对事件循环太慢的读属于 `rw`，那里的 FIFO worker 把它们排在写后面串行执行而绝不阻塞循环——只为这类工作接受额外的跳转。

要避免的失败模式是反向路由——把读重的负载压到 `rw` 上——那样往往次优：每次读都要付 worker 跳转与跨线程交接的代价，读还得在同一条连接上排在写后面排队。若延迟平平，先检查你的读落在哪个句柄上。

本驱动刻意**没有池**。单写路径就是设计本身：要更快，把点读路由到 `query_ro`——绝不加宽池。

## 所有权契约的验证

SQLite 无需服务器，所以验证材料就是提交进仓库的测试：

- `spec/sqlite3_spec.lua` —— surface、选项与路由校验。
- `test/smoke_sqlite3_contract.lua` —— 实机契约：内联 `ro` 不 yield、`rw` 的挂起/恢复、FIFO 顺序与并发同名调用者的各取所需、选项默认值与覆盖、启动失败清理、先失败后成功、close 排空。

`xmake build lunet-sqlite3 && xmake build-release` 之后运行：

```
xmake test
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" test/smoke_sqlite3_contract.lua
```

`test/smoke_sqlite3_tx.lua` 钉住事务包装器的控制流。
