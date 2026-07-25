# `lunet.mysql`

MySQL 驱动（libmysqlclient）。使用 `xmake build lunet-mysql` 构建，产物为
`lunet/mysql.so`。

占位符为 `?`。参数通过 `mysql_stmt_bind_param` 原生绑定，值永远不会被拼接进
SQL。本项目有意不提供 `db.escape`。

| 函数 | 说明 |
|---|---|
| `open(config)` | `host`、`port`、`user`、`password`、`database`、`charset` |
| `close(conn)` | |
| `query(conn, sql, ...)` | 返回行表数组 |
| `exec(conn, sql, ...)` | 返回 `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | 与上述行为一致 |

## 事务

使用 `lunet.mysql_tx`（`mysql_tx.lua`，与 `mysql.so` 一同发布）：

```lua
local mysql = require("lunet.mysql")
local tx = require("lunet.mysql_tx")

local ok, err = tx.transaction(conn, function(t)
    t.exec("DELETE FROM nodes WHERE path = ?", dst)
    local r = t.exec("UPDATE nodes SET path=? WHERE path=? AND version=?",
                     dst, src, version)
    if r.affected_rows == 0 then return nil, "version conflict" end
    return true
end)

if not ok and err.poisoned then mysql.close(conn) end
```

返回非 nil 值即提交；返回 `nil, reason` 或抛出错误则回滚。完整约定见
`mysql_tx.lua` 的头部注释。

**最关键的规则：** 事务属于**连接**，而不属于协程。若连接池在每次调用后都把连接
归还，开启事务、工作语句与 `COMMIT` 会落在三个不同的会话上，最终什么也没提交。
`transaction()` 在整个工作单元期间持有同一个连接——这正是它接收 `conn` 而不是
配置表的原因。

### 驱动特有事实（全部经实测，见下文）

- **`BEGIN` 与 `START TRANSACTION` 在本驱动下完全无法使用。** `mysql.c` 始终走
  `mysql_stmt_prepare`——不像 postgres 驱动那样存在非预处理路径——而 MySQL 的
  预处理语句协议会以 *"This command is not supported in the prepared statement
  protocol yet"* 拒绝它们。`COMMIT`、`ROLLBACK` 与 `SET autocommit` 是被接受的。
  因此 `mysql_tx.lua` 用 `SET autocommit=0` …… `COMMIT` / `SET autocommit=1`
  来界定事务。
- **`SAVEPOINT` 因同样原因被拒绝**，所以不支持嵌套事务。
- **恢复 autocommit 属于约定的一部分。** 停留在 `autocommit=0` 的连接会静默缓冲
  **下一个**调用方的写入。恢复失败会被报告为 `err.poisoned`。
- **DDL 会导致隐式提交。** 事务中的 `CREATE`/`ALTER`/`DROP`/`TRUNCATE` 会提交它
  之前的一切且无法回滚。绝不要在 `fn` 内执行 DDL。
- **MyISAM 会静默忽略事务。** 不会报错；写入只是不具备原子性，`ROLLBACK` 毫无
  作用。请使用 InnoDB。包装器无法检测这一点，因为 MySQL 不报告任何问题。
- 默认隔离级别是 `REPEATABLE-READ`（而非 Postgres 的 `READ COMMITTED`），因此在
  一个事务内重复 `SELECT` 始终返回首次的快照。请用 `t.exec` 返回的
  `affected_rows` 检测写冲突，而不是重新读取。

## 固定连接（pinning）是如何被人工验证的

这是针对真实服务器人工验证的，不是 mock。如果你修改了 `mysql_tx.lua` 或
`mysql.c` 的执行路径，请重做一次——成本很低，而上述“`BEGIN` 不受支持”与 MyISAM
两项发现正是这样被发现的，而非猜测出来的。

启动一个一次性服务器（不使用卷挂载，因此在 aarch64 的 Colima 下也可用；**不要**
传 `--default-authentication-plugin`，该参数在 8.4 中已被移除）：

```bash
docker run -d --name lunet-tx-mysql -e MYSQL_ROOT_PASSWORD=lunetpw \
  -e MYSQL_DATABASE=lunet_tx -p 13306:3306 mysql:8.4
```

初始化约需 30 秒；可用
`docker exec lunet-tx-mysql mysqladmin ping -uroot -plunetpw` 轮询。然后用
`.tmp/` 下的临时脚本驱动它（该目录已被 gitignore——有意不作为提交的测试，因为 CI
中不应有任何步骤需要启动数据库）。

真正值得保留的是方法论：

1. **先探测驱动实际能发送哪些语句**，不要凭假设。遍历 `BEGIN`、
   `START TRANSACTION`、`COMMIT`、`ROLLBACK`、`SET autocommit=0/1`、`SAVEPOINT`
   并打印哪些失败。正是这一步揭示了 `BEGIN` 不可用。
2. **打开两个连接：`worker` 与 `observer`。** 只通过 `observer` 统计行数。单个
   连接能看到自己未提交的修改，因此无法说明什么被真正提交了。
3. **先证明陷阱确实存在。** 在连接 A 上 `SET autocommit=0`，在连接 B 上执行
   `DELETE`，再在 A 上 `ROLLBACK`，并通过 observer 确认删除依然生效。
4. **再证明包装器堵住了它**：提交对 observer 可见；abort 与抛出错误两种情况都不
   改变 observer 看到的状态。
5. **检查事务中途的隔离性**：在 `fn` 内部查询 observer。
6. **确认 autocommit 已被恢复**——读取 `@@autocommit`，然后执行一次裸写入并确认
   observer 能看到它。跳过这一步会掩盖最糟的失败模式，因为泄漏的 `autocommit=0`
   破坏的是**之后**某个毫不相关的调用方。
7. **实测上述两个静默陷阱，而不是相信文档**：中止一个执行过 DDL 的事务，确认此前
   的 DML 已经落库；再对 MyISAM 表中止一个事务，确认行仍被删除且没有任何报错。

最近一次运行：针对 `mysql:8.4` 全部 25 项检查通过（2026-07-25）。
