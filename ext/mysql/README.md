# `lunet.mysql`

MySQL driver (libmysqlclient). Build with `xmake build lunet-mysql`; output is
`lunet/mysql.so`.

Placeholders are `?`. Parameters are bound natively via
`mysql_stmt_bind_param`, so values are never concatenated into SQL. There is
deliberately no `db.escape`.

| Function | Notes |
|---|---|
| `open(config)` | `host`, `port`, `user`, `password`, `database`, `charset` |
| `close(conn)` | |
| `query(conn, sql, ...)` | returns array of row tables |
| `exec(conn, sql, ...)` | returns `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | same behaviour as the above |

## Transactions

Use `lunet.mysql_tx` (`mysql_tx.lua`, shipped next to `mysql.so`):

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

Return non-nil to commit; return `nil, reason` or raise to roll back. See the
header comment in `mysql_tx.lua` for the full contract.

**The rule that matters:** a transaction belongs to the *connection*, not the
coroutine. A pool that checks a connection out per call and returns it
afterwards will scatter the transaction open, the work, and the `COMMIT` across
three different sessions and commit nothing. `transaction()` holds one
connection for the whole unit, which is why it takes a `conn` rather than a
config.

### Driver-specific facts (all measured, see below)

- **Booleans are bound as `MYSQL_TYPE_TINY` with `is_unsigned=1`.** MySQL has
  no distinct boolean column type on the wire — `BOOLEAN` is an alias for
  `TINYINT(1)`. A boolean insert stores 1/0 and the read-back returns an
  integer, not a Lua boolean. `MYSQL_TYPE_BOOL` is a documented placeholder in
  the header, not a wire type.
- **`BEGIN` and `START TRANSACTION` do not work through this driver at all.**
  `mysql.c` always goes through `mysql_stmt_prepare` — there is no
  non-prepared path as there is in the postgres driver — and MySQL's
  prepared-statement protocol rejects them with *"This command is not supported
  in the prepared statement protocol yet"*. `COMMIT`, `ROLLBACK` and
  `SET autocommit` are accepted. That is why `mysql_tx.lua` brackets the
  transaction with `SET autocommit=0` … `COMMIT` / `SET autocommit=1`.
- **`SAVEPOINT` is rejected for the same reason**, so nested transactions are
  not available.
- **Restoring autocommit is part of the contract.** A connection left at
  `autocommit=0` would silently buffer the *next* caller's writes. A failed
  restore is reported as `err.poisoned`.
- **DDL causes an implicit commit.** `CREATE`/`ALTER`/`DROP`/`TRUNCATE` inside a
  transaction commit everything before them and cannot be rolled back. Never
  issue DDL inside `fn`.
- **MyISAM silently ignores transactions.** No error is raised; the writes
  simply are not atomic and `ROLLBACK` does nothing. Use InnoDB. The wrapper
  cannot detect this because MySQL reports no problem.
- Default isolation is `REPEATABLE-READ` (not Postgres's `READ COMMITTED`), so
  a re-`SELECT` inside a transaction keeps returning the first snapshot. Detect
  write conflicts with `affected_rows` from `t.exec`, not by re-reading.

## How the pinning was verified

Verified by hand against a real server, not mocks. If you change `mysql_tx.lua`
or the execution path in `mysql.c`, redo this — it is cheap, and it is how the
`BEGIN`-is-unsupported and MyISAM findings above were discovered rather than
guessed.

Start a throwaway server (no volume mounts, so this works under Colima on
aarch64; do **not** pass `--default-authentication-plugin`, removed in 8.4):

```bash
docker run -d --name lunet-tx-mysql -e MYSQL_ROOT_PASSWORD=lunetpw \
  -e MYSQL_DATABASE=lunet_tx -p 13306:3306 mysql:8.4
```

It takes ~30s to initialise; poll with
`docker exec lunet-tx-mysql mysqladmin ping -uroot -plunetpw`. Then drive it
from a scratch script in `.tmp/` (gitignored — deliberately not a committed
test, since nothing in CI should need a database to boot).

The methodology, which is the part worth keeping:

1. **Probe what the driver can actually issue** before assuming anything. Loop
   over `BEGIN`, `START TRANSACTION`, `COMMIT`, `ROLLBACK`,
   `SET autocommit=0/1`, `SAVEPOINT` and print which ones fail. This is what
   revealed that `BEGIN` is unavailable.
2. **Open two connections: a `worker` and an `observer`.** Count rows only via
   the `observer`. A single connection can see its own uncommitted work, so it
   cannot tell you what was really committed.
3. **First prove the trap exists.** `SET autocommit=0` on connection A, do the
   `DELETE` on connection B, `ROLLBACK` on A, and confirm via the observer that
   the delete persisted.
4. **Then prove the wrapper closes it**: commit visible to the observer; abort
   and raise both leaving the observer's view untouched.
5. **Check isolation mid-transaction** by querying the observer from inside `fn`.
6. **Confirm autocommit was restored** — read `@@autocommit`, then do a bare
   write and confirm the observer sees it. Skipping this hides the worst failure
   mode, because a leaked `autocommit=0` breaks a *later* unrelated caller.
7. **Verify the two silent traps rather than trusting the notes above**: abort a
   transaction that issued DDL and confirm the earlier DML stuck; abort one
   against a MyISAM table and confirm the row stayed deleted with no error.

Last run: 25/25 checks passed against `mysql:8.4` (2026-07-25).
