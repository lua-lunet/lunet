# `lunet.postgres`

PostgreSQL 驱动（libpq）。使用 `xmake build lunet-postgres` 构建，产物为
`lunet/postgres.so`。

占位符为 `$1`、`$2` …… 参数通过 `PQexecParams` 原生绑定，值永远不会被拼接进
SQL。本项目有意不提供 `db.escape`。

| 函数 | 说明 |
|---|---|
| `open(config)` | `host`、`port`、`user`、`password`、`database` |
| `close(conn)` | |
| `query(conn, sql, ...)` | 返回行表数组 |
| `exec(conn, sql, ...)` | 返回 `{ affected_rows }` |
| `query_params` / `exec_params` | 与上述行为一致 |

## 事务

使用 `lunet.postgres_tx`（`postgres_tx.lua`，与 `postgres.so` 一同发布）：

```lua
local pg = require("lunet.postgres")
local tx = require("lunet.postgres_tx")

local ok, err = tx.transaction(conn, function(t)
    t.exec("DELETE FROM nodes WHERE path = $1", dst)
    local r = t.exec("UPDATE nodes SET path=$1 WHERE path=$2 AND version=$3",
                     dst, src, version)
    if r.affected_rows == 0 then return nil, "version conflict" end
    return true
end)

if not ok and err.poisoned then pg.close(conn) end
```

返回非 nil 值即提交；返回 `nil, reason` 或抛出错误则回滚。完整约定见
`postgres_tx.lua` 的头部注释。

**最关键的规则：** 事务属于**连接**，而不属于协程。若连接池在每次调用后都把
连接归还，`BEGIN`、中间的工作语句与 `COMMIT` 会落在三个不同的会话上，最终什么
也没提交。`transaction()` 在整个工作单元期间持有同一个连接——这正是它接收
`conn` 而不是配置表的原因。

### 驱动特有事实

- 不带参数时驱动使用 `PQexec`，它允许多条以 `;` 分隔的命令，但只返回最后一条的
  结果；带参数时使用 `PQexecParams`，直接拒绝多命令 SQL。
- 任何语句出错后，Postgres 会把会话置于 aborted 状态，直到 `ROLLBACK` 之前所有
  语句都会失败。本包装器会直接展开到 `ROLLBACK`，因此连接可以恢复；请不要捕获
  `t.*` 的错误后继续发送语句。

## 固定连接（pinning）是如何被人工验证的

这是针对真实服务器人工验证的，不是 mock。如果你修改了 `postgres_tx.lua` 或
`postgres.c` 中的事务处理，请重做一次——成本很低，而且能发现单元测试无法覆盖的
问题。

启动一个一次性服务器（不使用卷挂载，因此在 aarch64 的 Colima 下也可用）：

```bash
docker run -d --name lunet-tx-pg -e POSTGRES_PASSWORD=lunetpw \
  -e POSTGRES_DB=lunet_tx -p 15432:5432 postgres:17
```

然后用 `.tmp/` 下的临时脚本驱动它（该目录已被 gitignore——有意不作为提交的测试，
因为 CI 中不应有任何步骤需要启动数据库）。

真正值得保留的是方法论：

1. **打开两个连接：`worker` 与 `observer`。** 只通过 `observer` 统计行数。单个
   连接能看到自己未提交的修改，因此无法说明某件事是否真的提交了——这正是真实
   校验与自我印证之间的区别。
2. **先证明陷阱确实存在。** 在连接 A 上开启事务，在连接 B 上执行 `DELETE`，再在
   A 上 `ROLLBACK`，并通过 observer 确认删除依然生效。如果这条断言哪天开始失败，
   说明本模块所要防范的陷阱已经改变形态。
3. **再证明包装器堵住了它**：提交路径对 observer 可见；abort-by-nil 与抛出错误
   两种情况都不改变 observer 看到的状态。
4. **检查事务中途的隔离性。** 在 `fn` *内部*查询 observer，确认它看不到未提交的
   修改。
5. **验证恢复能力。** 在 `fn` 内制造语句错误，确认 `err.poisoned == false`，随后
   在 worker 上执行一次查询，证明连接经历 Postgres 的 aborted 状态后依然可用。
6. **验证 poisoned 路径**：关闭一个连接后对它调用 `transaction()`，此时 `BEGIN`
   失败，`err.poisoned` 必须为 `true`。

最近一次运行：针对 `postgres:17` 全部 19 项检查通过（2026-07-25）。
