# `lunet.sqlite3`

SQLite 驱动。使用 `xmake build lunet-sqlite3` 构建，产物为 `lunet/sqlite3.so`。

占位符为 `?`。参数通过 `sqlite3_bind_*` 原生绑定，值永远不会被拼接进 SQL。
本项目有意不提供 `db.escape`。

| 函数 | 说明 |
|---|---|
| `open(config)` | `{ path = "app.db" }` 或 `{ path = ":memory:" }` |
| `close(conn)` | |
| `query(conn, sql, ...)` | 返回行表数组 |
| `exec(conn, sql, ...)` | 返回 `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | 与上述行为一致 |

## 事务

使用 `lunet.sqlite3_tx`（`sqlite3_tx.lua`，与 `sqlite3.so` 一同发布）：

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

- **布尔值通过 `sqlite3_bind_int` 绑定。** SQLite 没有布尔类型，因此布尔写入存入
  1/0，读回返回整数而非 Lua 布尔值。这是驱动的有意行为——不存在一个能区分
  布尔的列类型可供读回比对。
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
