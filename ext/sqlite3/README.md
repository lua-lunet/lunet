# `lunet.sqlite3`

SQLite driver. Build with `xmake build lunet-sqlite3`; output is
`lunet/sqlite3.so`.

Placeholders are `?`. Parameters are bound natively via `sqlite3_bind_*`, so
values are never concatenated into SQL. There is deliberately no `db.escape`.

| Function | Notes |
|---|---|
| `open(config)` | `{ path = "app.db" }` or `{ path = ":memory:" }` |
| `close(conn)` | |
| `query(conn, sql, ...)` | returns array of row tables |
| `exec(conn, sql, ...)` | returns `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | same behaviour as the above |

## Transactions

Use `lunet.sqlite3_tx` (`sqlite3_tx.lua`, shipped next to `sqlite3.so`):

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

Return non-nil to commit; return `nil, reason` or raise to roll back. See the
header comment in `sqlite3_tx.lua` for the full contract.

**The rule that matters:** a transaction belongs to the *connection*, not the
coroutine. A pool that checks a handle out per call and returns it afterwards
will scatter `BEGIN`, the work, and `COMMIT` across handles and commit nothing.
`transaction()` holds one handle for the whole unit, which is why it takes a
`conn` rather than a config.

### Driver-specific facts

- **Booleans are bound as `sqlite3_bind_int`.** SQLite has no boolean type, so a
  boolean insert stores 1/0 and the read-back returns an integer, not a Lua
  boolean. This is the driver's intentional behaviour — there is no
  boolean-distinguishing column type to read back against.
- **Pass `"IMMEDIATE"` for anything that writes.** The third argument is the
  locking mode. SQLite's default `DEFERRED` takes no lock until the first
  statement, so another writer can grab the write lock first and your `UPDATE`
  fails with `SQLITE_BUSY` *after* `BEGIN` succeeded. `IMMEDIATE` moves that
  failure up front. `EXCLUSIVE` also blocks readers.
- Unlike Postgres, a statement error does not poison the session — SQLite lets
  you catch a `t.*` error inside `fn` and continue. Usually still wrong, but it
  will not fail every later statement.
- **`query`/`exec` bind parameters.** They did not until 2026-07-25: only
  `query_params`/`exec_params` called `collect_params`, so
  `db.exec(conn, "INSERT INTO t VALUES (?,?)", a, b)` left both placeholders
  unbound (i.e. `NULL`) and reported success. If you touch `lunet_db_query` or
  `lunet_db_exec` in `sqlite3.c`, keep the `collect_params` call — a regression
  here is silent data loss, not a crash.

## How the pinning was verified

SQLite needs no server, so this one *is* a committed test:
`test/smoke_sqlite3_tx.lua` (21 checks). Run it with
`lunet-run test/smoke_sqlite3_tx.lua` after
`xmake build lunet-sqlite3 && xmake build-release`.

The methodology, which is the part worth keeping — mirroring what was done by
hand for the postgres and mysql drivers (see their READMEs):

1. Cover both outcomes and both abort routes: commit, abort-by-nil, raise
   inside `fn`, and a statement error inside `fn`. Each abort must leave the
   pre-transaction state intact.
2. Assert on `affected_rows` from `t.exec` inside the transaction — that is the
   compare-and-set signal, and `t.query` does not report it.
3. Assert `err.poisoned == false` after a clean rollback, and prove the
   connection still works afterwards.
4. Cover the guards: invalid locking mode, nil connection, non-function body.
5. Because SQLite is single-file, there is no second-session observer as there
   is for postgres/mysql. That is the one thing this test *cannot* show, so
   treat the postgres run as the real proof of isolation and this as the proof
   of the wrapper's control flow.

Last run: 21/21 checks passed (2026-07-25).
