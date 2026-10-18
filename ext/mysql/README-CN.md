# `lunet.mysql`

MySQL 驱动（libmysqlclient）。可以直接 `require("lunet.mysql")` 发布压缩包
中的预构建模块（`lunet/mysql.so`；压缩包布局见
[docs/RELEASE-LAYOUT-CN.md](../docs/RELEASE-LAYOUT-CN.md)），也可以自己用
`xmake build lunet-mysql` 构建，产物为 `lunet/mysql.so`。

占位符为 `?`。参数通过 `mysql_stmt_bind_param` 原生绑定，值永远不会被拼接进
SQL。本项目有意不提供 `db.escape`。

| 函数 | 说明 |
|---|---|
| `open(config)` | `host`、`port`、`user`、`password`、`database`、`charset`，可选 `connect_timeout`、`pool_size`（默认 1） |
| `close(conn)` | |
| `query(conn, sql, ...)` | 返回行表数组 |
| `exec(conn, sql, ...)` | 返回 `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | 与上述行为一致 |

### 打开参数（Open settings）

`open` 接受一个参数表，包含下表所列设置。除 `host` 等连接目标外，其余字段在
运行时均可省略；类型错误会在打开时大声报错，绝不会被静默忽略。

| 参数 | 类型 | 语义 |
|---|---|---|
| `host` | string | 默认 `"localhost"` |
| `port` | integer | 默认 `3306` |
| `user` | string | 默认 `"root"` |
| `password` / `database` | string | 默认 `""` |
| `charset` | string | 默认 `"utf8mb4"`，通过 `MYSQL_SET_CHARSET_NAME` 生效 |
| `connect_timeout` | integer | libmysqlclient 连接尝试的等待秒数；不设置则保持库默认值 |
| `pool_size` | integer | 默认 `1`；见下文 |

透传语义：`connect_timeout` 在句柄返回**之前**就已生效——驱动在对池中每一条连接
调用 `mysql_real_connect` 之前先设置 `MYSQL_OPT_CONNECT_TIMEOUT`，因此它对你最先
接触的连接以及所有连接同时生效。驱动不会替供应商发明默认值：省略字段，
libmysqlclient 的行为就与其手册所述完全一致。

该句柄没有打开后的 pragma 通道——没有作为 API 暴露的 `SET` 逃生舱口，也没有会话
级旋钮。打开时的设置就是全部约定。（sqlite3 风格的读/写拆分有意不适用于远程
驱动：服务器自身负责读/写流量的路由。）

### `pool_size`

`open` 接受 `pool_size`（默认 **1**）：返回句柄背后的服务器连接数。一条语句 →
一个成员，派发时轮转选取；`close` 关闭全部成员。MySQL 本就服务并发的客户端
连接，因此更宽的池能并行化真实工作——在这里这是正经特性，不是逃生舱口。

**`mysql_tx` 要求默认 `pool_size = 1`。** 事务属于*连接*；多成员池在构造上就
违反了这一点——`BEGIN` 与 `COMMIT` 可能落在不同会话上，最终什么也没提交。

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
