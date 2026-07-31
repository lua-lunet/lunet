# `lunet.postgres`

PostgreSQL driver (libpq). Build with `xmake build lunet-postgres`; output is
`lunet/postgres.so`.

Placeholders are `$1`, `$2`, … Parameters are bound natively via
`PQexecParams`, so values are never concatenated into SQL. There is
deliberately no `db.escape`.

| Function | Notes |
|---|---|
| `open(config)` | `host`, `port`, `user`, `password`, `database` |
| `close(conn)` | |
| `query(conn, sql, ...)` | returns array of row tables |
| `exec(conn, sql, ...)` | returns `{ affected_rows }` |
| `query_params` / `exec_params` | same behaviour as the above |

## Transactions

Use `lunet.postgres_tx` (`postgres_tx.lua`, shipped next to `postgres.so`):

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

Return non-nil to commit; return `nil, reason` or raise to roll back. See the
header comment in `postgres_tx.lua` for the full contract.

**The rule that matters:** a transaction belongs to the *connection*, not the
coroutine. A pool that checks a connection out per call and returns it
afterwards will scatter `BEGIN`, the work, and `COMMIT` across three different
sessions and commit nothing. `transaction()` holds one connection for the whole
unit, which is why it takes a `conn` rather than a config.

### Driver-specific facts

- No parameters → the driver uses `PQexec`, which accepts multiple `;`-separated
  commands but returns only the last one's results. With parameters it uses
  `PQexecParams`, which rejects multi-command SQL outright.
- After any statement error, Postgres puts the session in an aborted state where
  everything fails until `ROLLBACK`. The wrapper unwinds straight to `ROLLBACK`,
  so the connection recovers; don't catch a `t.*` error and keep issuing
  statements.

## How the pinning was verified

Verified by hand against a real server, not mocks. If you change
`postgres_tx.lua` or the transaction handling in `postgres.c`, redo this — it is
cheap and it catches the things unit tests cannot.

Start a throwaway server (no volume mounts, so this works under Colima on
aarch64):

```bash
docker run -d --name lunet-tx-pg -e POSTGRES_PASSWORD=lunetpw \
  -e POSTGRES_DB=lunet_tx -p 15432:5432 postgres:17
```

Then drive it from a scratch script in `.tmp/` (gitignored — deliberately not a
committed test, since nothing in CI should need a database to boot).

The methodology, which is the part worth keeping:

1. **Open two connections: a `worker` and an `observer`.** Count rows only via
   the `observer`. A single connection cannot tell you whether something was
   really committed, because it can see its own uncommitted work — this is what
   separates a real check from a self-confirming one.
2. **First prove the trap exists.** Open a transaction on connection A, do the
   `DELETE` on connection B, `ROLLBACK` on A, and confirm via the observer that
   the delete persisted. If that assertion ever starts failing, the trap this
   module exists to prevent has changed shape.
3. **Then prove the wrapper closes it**: commit path visible to the observer;
   abort-by-nil and raise both leaving the observer's view untouched.
4. **Check isolation mid-transaction.** Query the observer from *inside* `fn`
   and confirm it cannot see the uncommitted change.
5. **Exercise recovery.** Force a statement error inside `fn`, confirm
   `err.poisoned == false`, then run a query on the worker to prove the
   connection survived Postgres's aborted-session state.
6. **Exercise the poison path** by closing a connection and calling
   `transaction()` on it: `BEGIN` fails and `err.poisoned` must be `true`.

Last run: 19/19 checks passed against `postgres:17` (2026-07-25).
