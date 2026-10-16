# `lunet.sqlite3`

SQLite 驱动。可以直接 `require("lunet.sqlite3")` 发布压缩包中的预构建模块
（`lunet/sqlite3.so`；压缩包布局见
[docs/RELEASE-LAYOUT-CN.md](docs/RELEASE-LAYOUT-CN.md)），也可以自己用
`xmake build lunet-sqlite3` 构建，产物为 `lunet/sqlite3.so`。

占位符为 `?`。参数通过 `sqlite3_bind_*` 原生绑定，值永远不会被拼接进 SQL。
本项目有意不提供 `db.escape`。

| 函数 | 说明 |
|---|---|
| `open(config)` | `{ path = "app.db" }` 或 `{ path = ":memory:" }`；返回**两个**连接 —— `(rw, ro, err)` |
| `close(conn)` | 可独立关闭任一句柄 |
| `query(conn, sql, ...)` | 返回行表数组 |
| `exec(conn, sql, ...)` | 返回 `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | 与上述行为一致 |

## 读与写

`open` 返回两个连接：

```lua
local db = require("lunet.sqlite3")

lunet.spawn(function()
  local rw, ro, err = db.open({ path = "app.db" })
  if not rw then error(err) end

  -- 写者上的一次性设置：WAL 让读者与唯一的写者互不阻塞。
  assert(db.exec(rw, "PRAGMA journal_mode=WAL"))

  -- 写入走 rw（照旧进入 worker 池）……
  assert(db.exec(rw, "INSERT INTO t VALUES (?)", 1))

  -- ……读取走 ro：在读句柄上语句在循环线程内联执行——
  -- 不经过 worker，不发生 yield。
  local rows = assert(db.query(ro, "SELECT * FROM t"))

  db.close(rw)
  db.close(ro)
end)
```

- `rw` —— 读写连接，即本变更之前 `open` 返回的唯一句柄：单写者、每连接互斥锁、
  语句派发到 uv worker 池。
- `ro` —— 以 `SQLITE_OPEN_READONLY` 打开的第二个连接，用于读流量。其上的
  `query`/`exec` 在循环线程内联执行。WAL 模式下读者与写者互不阻塞，因此
  循环线程路径就是快路径；同样的负载按此路由实测 p95 比全部语句挤进一个
  池化句柄快约 4 倍。
- **失败形态：** 打开失败时两个句柄均为 `nil`，错误是第三个返回值 ——
  `local rw, ro, err = db.open(...)`。这是 sqlite3 驱动特有的形态：网络驱动
  仍保持 `(conn, err)`。
- 忽略 `ro`、只使用 `rw` 的消费者，行为与从前完全一致。
- **路由是消费者在构建期拥有的正确性。** 没有读写语句标记，也没有派发机制。
  误路由到 `ro` 的写语句在 `prepare` 阶段成功（廉价解析，不加锁），在 `step`
  阶段响亮失败并返回 `SQLITE_READONLY`（"attempt to write a readonly
  database"）——绝不可能静默提交。`sqlite3_db_readonly(ro, "main")` 仍在底层
  可用，供测试把不变量当一等断言使用。
- 用完请分别对两个句柄调用 `db.close`；它们是相互独立的连接。

## 事务

使用 `lunet.sqlite3_tx`（`sqlite3_tx.lua`，与 `sqlite3.so` 一同发布）。
事务请放在 `rw` 句柄上。

```lua
local sqlite = require("lunet.sqlite3")
local tx = require("lunet.sqlite3_tx")

local ok, err = tx.transaction(conn, function(t)
    t.exec("DELETE FROM nodes WHERE path = ?", dst)
    local r = t.exec("UPDATE nodes SET path=? WHERE path=? AND version=?",
                     dst, src, version)
    if r.affected_rows == 0 then return nil, "version conflict" end
    return true
end, "IMMEDIATE")

if not ok and err.poisoned then sqlite.close(conn) end
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
- **读写拆分需要文件路径。** `:memory:` 无法拆分：对 `":memory:"` 以
  `SQLITE_OPEN_READONLY` 再开的第二个连接是一个全新、空、私有的数据库——
  不是写者数据的读者。打算使用 `ro` 时请传文件路径；在 `:memory:` 上只用
  `rw` 即可。

## 固定连接（pinning）是如何被人工验证的

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
