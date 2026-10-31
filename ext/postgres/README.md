# `lunet.postgres`

PostgreSQL driver (libpq). Either `require("lunet.postgres")` a prebuilt
module straight from a release archive (`lunet/postgres.so`; see the archive
layout in [docs/RELEASE-LAYOUT.md](../docs/RELEASE-LAYOUT.md)), or build it
yourself with `xmake build lunet-postgres`; output is `lunet/postgres.so`.

Placeholders are `$1`, `$2`, … Parameters are bound natively via
`PQexecParams`, so values are never concatenated into SQL. There is
deliberately no `db.escape`.

**Client library floor: libpq 17 or newer.** The driver is built against
libpq and will not compile (or load) against libpq 16 or older; a host
with an older client library fails at build time with a named error
rather than silently producing an unusable module. Install libpq 17+ (see
[RELEASE-LAYOUT.md](../docs/RELEASE-LAYOUT.md)).

| Function | Notes |
|---|---|
| `open(config)` | `host`, `port`, `user`, `password`, `database`, optional `connect_timeout`, `sslmode`, `pool_size` (default 1) |
| `close(conn)` | |
| `query(conn, sql, ...)` | returns array of row tables |
| `exec(conn, sql, ...)` | returns `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | same behaviour as the above |
| `prepare(conn, sql)` | reusable prepared statement; `stmt:query` / `stmt:exec` / `stmt:close`; requires a single connection (`pool_size = 1` or a checked-out member) — see [Prepared statements](#prepared-statements) |
| `checkout(pool)` | check one member out of the pool exclusively: returns a connection handle bound to a single server session, removed from the round-robin rotation until released. The mechanism for transaction stickiness. |
| `release(conn)` | return a checked-out member to the rotation. Idempotent after pool close. |

### Open settings

`open` accepts a params table with the settings below. Everything except
`host` and friends is optional at runtime; wrong types and unknown values
raise a loud error at open time rather than being silently ignored.

| Param | Type | Semantics |
|---|---|---|
| `host` | string | default `"localhost"` |
| `port` | integer | default `5432` |
| `user` / `password` / `database` | string | defaults `""` |
| `connect_timeout` | integer | seconds libpq waits before the connect attempt fails; unset leaves the libpq default untouched |
| `sslmode` | string | one of `"disable"`, `"allow"`, `"prefer"`, `"require"`, `"verify-ca"`, `"verify-full"`; unset leaves the libpq default untouched |
| `pool_size` | integer | default `1`; see below |

Passthrough semantics: `connect_timeout` and `sslmode` are applied before the
handle returns — they go into the libpq conninfo string the driver assembles
and are in force for every connection in the pool, including the first one you
touch. The driver never invents a value the vendor already defaults: omit the
field and libpq behaves exactly as libpq documents.

There is no post-open pragma surface on this handle — no `SET` escape hatch,
no per-session knob. Open-time settings are the entire contract. (The
sqlite3-style read/write split deliberately does not apply to remote drivers:
the server routes read/write traffic itself.)

### `pool_size`

`open` accepts `pool_size` (default **1**): how many server connections sit
behind the returned handle. One statement → one member, picked round-robin
at dispatch; `close` closes all members. Postgres genuinely serves
concurrent client connections, so a wider pool parallelises real work —
this is a feature here, not an escape hatch.

**Transaction stickiness.** A transaction belongs to the *connection*, so
`BEGIN`/`COMMIT` must land on the same session. A multi-member pool
violates that by construction — `BEGIN` and `COMMIT` can round-robin
onto different sessions and commit nothing. Two ways to stay safe:

- open with the default `pool_size = 1` and pass that handle to
  `postgres_tx`, as before;
- open with `pool_size = N` and `checkout` a member for the whole
  transaction, hand that member to `postgres_tx.transaction`, then
  `release` it when the transaction is done (or let its GC release it).
  `postgres_tx` itself needs no change — it already holds whatever
  connection it is given.

## Exclusive checkout

`checkout(pool)` returns a connection handle bound to a single server
session, removed from the pool's round-robin rotation for as long as
it is checked out. Every call on that handle (`query`, `exec`,
`query_params`, `exec_params`, `prepare`) targets that session, so a
`BEGIN` … `COMMIT` sequence stays on one connection even when the pool
has many members.

```lua
local pg = require("lunet.postgres")
local tx = require("lunet.postgres_tx")

local pool = pg.open({ host = "...", pool_size = 4 })
local conn = pg.checkout(pool)          -- a dedicated session
local ok, err = tx.transaction(conn, function(t)
    t.exec("DELETE FROM nodes WHERE path = $1", dst)
    local r = t.exec("UPDATE nodes SET path = $1 WHERE path = $2 AND version = $3",
                     dst, src, version)
    if r.affected_rows == 0 then return nil, "version conflict" end
    return true
end)
pg.release(conn)                        -- back in the rotation
```

Rules:

- **One member, one owner.** A checked-out member is taken out of the
  rotation; the remaining members keep serving autocommit traffic.
- **Exhaustion is loud, not a wait.** When every member is checked out,
  the next `checkout` returns `(nil, err)` — the driver does not queue
  or yield. Backpressure is app policy: sleep and retry, or size the pool.
- **Release is idempotent after close.** `release` on a handle whose
  pool is already closed returns `nil`. A double release on a live
  handle fails loudly.
- **A dropped checkout releases itself.** If a checked-out handle is
  garbage-collected without an explicit `release`, its member goes back
  into the rotation at GC time. The member is never closed by that path
  — the pool owns its members and closes them at pool close.
- **Statements bind to the member they were prepared on.** `prepare` on a
  checked-out conn works (it targets that session); `prepare` on a pool
  handle still requires a single member.

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

## Prepared statements

`prepare` exposes libpq's explicit prepared-statement protocol: the SQL is
prepared once (`PQprepare`) and each call executes it (`PQexecPrepared`) —
no per-call parse + plan on the server.

```lua
local stmt, err = pg.prepare(conn, "SELECT name FROM users WHERE age > $1")
if not stmt then error(err) end

local rows, qerr = stmt:query(30)   -- same binding semantics as query
stmt:close()                        -- PQclosePrepared, one worker hop
```

- `stmt:query(...)` / `stmt:exec(...)` bind the varargs per call, exactly
  like `query` / `exec`; each call is one `PQexecPrepared` on the
  statement's connection.
- **One statement is bound to one connection.** Prepared-statement names
  are session-scoped in libpq, so `prepare` on a pool handle requires
  `pool_size = 1` (the default) and fails loudly otherwise. A checked-out
  member is itself a single connection, so `prepare` works on it too —
  the statement binds to that session. Same doctrine as `postgres_tx`,
  which now takes a checked-out member for multi-member pools.
- If the connection dies, the statement dies with the session: use fails
  loudly (`statement is closed` / `connection is closed`).
- **Busy discipline:** one statement, one in-flight call. A second
  concurrent call on the same statement fails with `statement is busy`
  instead of interleaving on the connection.
- `stmt:close()` releases the server-side definition (one worker hop);
  after it, use fails loudly. A statement dropped without `close` leaves
  its server-side definition allocated until the session ends — the
  finalizer never sends network traffic, so call `close`.
- Closing the connection severs every statement still open on it.

Is it worth it? For a trivial statement the per-call server plan is
unmeasurable; for a complex or high-rate one it can matter. Read the
PostgreSQL documentation on the extended query protocol and decide for
your own workload — there is no magic.

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
