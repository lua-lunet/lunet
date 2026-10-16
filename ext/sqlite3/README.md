# `lunet.sqlite3`

SQLite driver. Either `require("lunet.sqlite3")` a prebuilt module straight
from a release archive (`lunet/sqlite3.so`; see the archive layout in
[docs/RELEASE-LAYOUT.md](docs/RELEASE-LAYOUT.md)), or build it yourself with
`xmake build lunet-sqlite3`; output is `lunet/sqlite3.so`.

Placeholders are `?`. Parameters are bound natively via `sqlite3_bind_*`, so
values are never concatenated into SQL. There is deliberately no `db.escape`.

| Function | Notes |
|---|---|
| `open(config)` | `{ path = "app.db" }` or `{ path = ":memory:" }`, optional `pool_size` (default 1); returns **two** connections — `(rw, ro, err)` |
| `close(conn)` | close either handle independently |
| `query(conn, sql, ...)` | returns array of row tables |
| `exec(conn, sql, ...)` | returns `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | same behaviour as the above |

## Reads and writes

`open` returns two connections:

```lua
local db = require("lunet.sqlite3")

lunet.spawn(function()
  local rw, ro, err = db.open({ path = "app.db" })
  if not rw then error(err) end

  -- One-time setup on the writer: WAL makes readers uncontended
  -- against the single writer.
  assert(db.exec(rw, "PRAGMA journal_mode=WAL"))

  -- Writes go to rw (worker pool, as always)...
  assert(db.exec(rw, "INSERT INTO t VALUES (?)", 1))

  -- ...reads go to ro: they execute inline on the loop thread —
  -- no worker hop, no yield.
  local rows = assert(db.query(ro, "SELECT * FROM t"))

  db.close(rw)
  db.close(ro)
end)
```

- `rw` — the read-write connection, the only handle `open` returned before
  this change: one writer, per-connection mutex, statements dispatched to
  the uv worker pool.
- `ro` — a second connection opened with `SQLITE_OPEN_READONLY`, for read
  traffic. Queries and execs on it run inline on the loop thread. In WAL
  mode readers never contend with the writer, so the loop-thread hop is the
  fast path; the same workload routed this way measured ~4x better p95 than
  routing every statement through a single pooled handle. The reasoning and
  the measurements live in [SQLITE.md](SQLITE.md) (Chinese:
  [SQLITE-CN.md](SQLITE-CN.md)).
- **Failure shape:** on open failure both handles are `nil` and the error is
  the third return — `local rw, ro, err = db.open(...)`. This is a
  sqlite3-specific shape: the network drivers keep `(conn, err)`.
- A consumer who ignores `ro` gets the old behaviour unchanged.
- **Routing is build-time correctness the consumer owns.** There is no
  read/write tagging and no dispatch machinery. A write mis-routed to `ro`
  parses fine at `prepare` (cheap, no locks) and fails loudly at `step` with
  `SQLITE_READONLY` ("attempt to write a readonly database") — it can never
  commit silently. `sqlite3_db_readonly(ro, "main")` stays available
  underneath for tests that want the invariant as a first-class assertion.
- Close each handle with `db.close` when done; they are independent
  connections.

### `pool_size`: an escape hatch, not a performance knob

`open` accepts `pool_size` (default **1**): how many connections sit behind
the `rw` handle, one statement → one member, picked round-robin at dispatch.
Leave it at the default — the single-writer tuned setup — and route reads
down `ro`. Raising it is **never** for performance: SQLite commits one write
at a time, and reads already run concurrently on the loop thread. It exists
so sloppy code (a pool of interchangeable connections, a port from a network
driver's habits) can run at all. `ro` never honours it. Two consequences:
`sqlite3_tx` requires the default `pool_size = 1` (a multi-member pool
breaks connection affinity — `BEGIN` and `COMMIT` can land on different
connections and commit nothing), and writes still serialise. Full reasoning
in [SQLITE.md](SQLITE.md).

## Transactions

Use `lunet.sqlite3_tx` (`sqlite3_tx.lua`, shipped next to `sqlite3.so`).
Transactions belong on the `rw` handle — which means `pool_size` at its
default of 1: a transaction belongs to the *connection*, and a multi-member
pool violates that by construction.

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
- **The split needs a file path.** `:memory:` cannot be split: a second
  connection opened `SQLITE_OPEN_READONLY` on `":memory:"` is a new, empty,
  private database — not a reader on the writer's data. Pass a file path
  whenever you intend to use `ro`; on `:memory:` simply use `rw` alone.

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
