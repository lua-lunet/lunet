# `lunet.sqlite3`

SQLite driver. Either `require("lunet.sqlite3")` a prebuilt module straight
from a release archive (`lunet/sqlite3.lua` + `lunet/sqlite3core.so`; see the
archive layout in [docs/RELEASE-LAYOUT.md](../docs/RELEASE-LAYOUT.md)), or
build it yourself with `xmake build lunet-sqlite3`. This page is the complete
reference: the API, the handle lifetimes, and the performance model — the
*why* behind the shape.

Placeholders are `?`. Parameters are bound natively via `sqlite3_bind_*`, so
values are never concatenated into SQL. There is deliberately no `db.escape`.

> ## Read this before using the read-only connection
>
> Under some workloads it is possible to get peak performance by opening in
> WAL mode and running reads on the read-only connection, which runs without
> a background thread — and therefore **risks stalling the main loop**.
> Whether that trade works for you depends entirely on your workload and on
> the SQLite version you link against; there are many caveats. **Read and
> understand the [SQLite documentation](https://sqlite.org/wal.html) before
> relying on it.** Set whatever settings you want — what will work depends
> on your workload.
>
> **If in doubt, do not use the read-only connection. Send everything down
> the read-write connection.** If it stalls, blocks or misbehaves, that is
> on not reading this warning — the driver does exactly what is documented
> here and nothing else. There is no magic.

## Surface

| Function | Notes |
|---|---|
| `open(config)` | `{ path = "app.db" }`, optionally `create = "WAL"|"NORMAL"` and the passthrough settings (`busy_timeout` ms, `foreign_keys` bool, `synchronous` "OFF"\|"NORMAL"\|"FULL"); **caches** the `(rw, ro)` pair keyed on the path string — `:memory:` is never cached |
| `open_raw(config)` | same config as `open`, but always opens a fresh pair; the cache is bypassed |
| `destroy(path)` | close both cached handles for a path and clear the cache entry; no-op if none |
| `close(conn)` | close a single handle (the `open_raw` lifetime) |
| `query(conn, sql, ...)` | returns array of row tables |
| `exec(conn, sql, ...)` | returns `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | same behaviour as the above |
| `prepare(conn, sql)` | reusable prepared statement; `stmt:query` / `stmt:exec` / `stmt:close` — see [Prepared statements](#prepared-statements) |

The split of responsibilities: the binary (`lunet.sqlite3core`) owns the
async I/O — one worker-hop open returning `(rw, ro, err)`, statements
dispatched to the uv worker pool on `rw`, executed inline on the loop thread
on `ro`. The Lua loader owns the policy — the path-keyed cache, `open_raw`,
`destroy`. Neither reaches into the other's job; the Lua cache cannot
mis-handle the C stack and the C core cannot grow cache policy. All calls
must run inside a coroutine spawned via `lunet.spawn`.

## The open contract

```lua
local db = require("lunet.sqlite3")

-- 1. Existing, provisioned database file. The driver opens it read-write
--    and never touches its journal mode. A missing file is a loud error —
--    provisioning (creating the file, setting WAL) is a deployment act:
--      sqlite3 app.db "PRAGMA journal_mode=WAL;"
local rw, ro, err = db.open({ path = "app.db" })

-- 2. Let the driver create the file — the mode is declared at creation:
local rw, ro, err = db.open({ path = "app.db", create = "WAL" })
--    create = "WAL"    -> creates the file and sets journal_mode=WAL (the
--                         pragma's return value is checked; a filesystem
--                         that cannot host WAL fails the open loudly).
--    create = "NORMAL" -> creates the file, journal mode stays at the
--                         SQLite default (rollback journal).
--    There is no "un-WAL": WAL is persistent for the file, and the driver
--    never changes the mode of an existing file on its own. On an existing
--    file create=WAL re-issues the pragma (idempotent); create=NORMAL
--    leaves the mode alone.

-- 3. Informed-user passthroughs, applied to BOTH connections at open:
local rw, ro, err = db.open({
    path = "app.db", create = "WAL",
    busy_timeout = 3000,        -- ms: the busy handler on each connection
    foreign_keys = true,        -- PRAGMA foreign_keys (off by vendor default)
    synchronous  = "NORMAL",    -- durability trade; never a driver default
})

-- 4. Unit tests: swap the path for :memory: and the same code shape runs.
--    One connection is returned as BOTH handles; create= is ignored and
--    ro does not enforce read-only there. :memory: is never cached —
--    every open is a fresh private database.
local rw, ro, err = db.open({ path = ":memory:" })
```

The passthroughs are per-connection and last-write-wins — after open, tune
either handle independently:

```lua
db.exec(rw, "PRAGMA busy_timeout = 5000")  -- rw only; ro keeps the open value
```

## Reads and writes

`open` returns two connections:

```lua
local db = require("lunet.sqlite3")

lunet.spawn(function()
  local rw, ro, err = db.open({ path = "app.db", create = "WAL" })
  if not rw then error(err) end

  -- Writes go to rw (worker pool, as always)...
  assert(db.exec(rw, "INSERT INTO t VALUES (?)", 1))

  -- ...reads go to ro: they execute inline on the loop thread —
  -- no worker hop, no yield.
  local rows = assert(db.query(ro, "SELECT * FROM t"))

  db.destroy("app.db")
end)
```

- `rw` — the read-write connection: one writer, per-connection mutex,
  statements dispatched to the uv worker pool. It also reads: it is the
  general connection, and the only one that writes.
- `ro` — a second connection opened with `SQLITE_OPEN_READONLY`, for read
  traffic. **Queries and execs on it run inline on the loop thread — there
  is no background thread and no yield.** In WAL mode readers never contend
  with the writer, so the loop-thread hop is the fast path; the trade is
  that a heavy read (large scan, cold page cache) stalls every coroutine,
  socket and timer for its duration. If you do not want the inline reader,
  discard it by convention — `local rw, _ = db.open({ path = "app.db" })`
  (`_` is Lua convention, not a language feature; the ro connection still
  exists until `destroy(path)`, at the cost of one file descriptor).
- **Failure shape:** on open failure both handles are `nil` and the error is
  the third return — `local rw, ro, err = db.open(...)`. This is a
  sqlite3-specific shape: the network drivers keep `(conn, err)`.
- **Handle lifetimes:** handles from `open` are closed via `destroy(path)`
  (both together, cache entry cleared); handles from `open_raw` are closed
  per-handle via `close`. A cached handle closed via `close` leaves the
  cache entry holding a dead pair — don't.
- A consumer who ignores `ro` gets the old single-connection behaviour.
- **Routing is build-time correctness the consumer owns.** There is no
  read/write tagging and no dispatch machinery. A write mis-routed to `ro`
  parses fine at `prepare` (cheap, no locks) and fails loudly at `step` with
  `SQLITE_READONLY` ("attempt to write a readonly database") — it can never
  commit silently. `sqlite3_db_readonly(ro, "main")` stays available
  underneath for tests that want the invariant as a first-class assertion.
- **Snapshots:** a `ro` read sees the committed state at the moment the read
  starts. Read-after-write within the same instant is stale on `ro`; route
  consistency-critical reads through `rw` (each call is a fresh read
  transaction, so a read issued after the write call returns is current).

## The single write thread

Statements on the `rw` handle execute on the libuv global thread pool; a
statement cannot start until the previous one on that connection finishes,
whatever the pool size. The single-writer contract this driver is built
around nevertheless calls for the pool itself to be one thread. With
`UV_THREADPOOL_SIZE=1` the write work literally runs on one background
thread: statements queue in dispatch order, and no other pool job of the
process (`fs`, `dns`, another driver's handle) can hold the worker a write
statement is waiting behind.

- The libuv default is 4. The variable must be set before the process
  starts: a shell prefix (`UV_THREADPOOL_SIZE=1 lunet-run app.lua`),
  systemd `Environment=`, docker `ENV`, and the like.
- The per-connection mutex is what keeps one connection's own statements
  correctly serialized at any pool size. One worker is the documented
  shape, not a lock substitute.
- If the pool is wider, the shape still works but the one-thread contract
  above no longer holds: another pool job can run on a second worker while
  a write statement is in flight.

## The performance model

A performance-tuning exercise on a fixed-API SQLite-backed HTTP service —
[lua-lunet/twelve-dollar-server-challenge](https://github.com/lua-lunet/twelve-dollar-server-challenge)
— demonstrated the shape of the optimal setup, and this driver is that
shape:

- **Separate reads from writes.** One connection owns writes; the read-only
  connection serves reads. In WAL mode readers never contend with the
  single writer, so the two paths never block each other.
- **A single thread for writes.** SQLite allows exactly one writer at a
  time; more writer connections buy nothing and only add contention.
- **Concurrent reads on the read-only connection, executed on the loop
  thread.** Reads on a `SQLITE_OPEN_READONLY` connection are pure CPU work
  against the page cache: running them inline — no worker-pool hop, no
  yield, no cross-thread handoff — removed the largest per-request cost on
  the read path. In that tuning the split measured ~4x better p95 across
  the load band than routing every statement through a single pooled
  handle, with zero `SQLITE_BUSY` events in every configuration.

The failure mode to avoid: the inverse routing — sending a read-heavy load
down the `rw` connection — is potentially suboptimal: every read pays the
worker-pool hop and the cross-thread handoff, and reads queue behind writes
on the same connection. If you see mediocre latency, check which handle
your reads are on before anything else.

There is deliberately **no pooling on this driver**. The single write path
IS the design: to go faster, route reads to `ro` — never widen a pool. The
`open`/`open_raw`/`destroy` trio exists so the right shape is also the
easy shape: open once per path (cached), read from `ro`, destroy when done.

## Transactions

Use `lunet.sqlite3_tx` (`sqlite3_tx.lua`, shipped next to the binary).
Transactions belong on the `rw` handle.

```lua
local sqlite = require("lunet.sqlite3")
local tx = require("lunet.sqlite3_tx")

local ok, err = tx.transaction(rw, function(t)
    t.exec("DELETE FROM nodes WHERE path = ?", dst)
    local r = t.exec("UPDATE nodes SET path=? WHERE path=? AND version=?",
                     dst, src, version)
    if r.affected_rows == 0 then return nil, "version conflict" end
    return true
end, "IMMEDIATE")

if not ok and err.poisoned then db.destroy(path) end
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

## Prepared statements

`prepare` keeps the vendor statement alive instead of parsing + planning
per call: the SQL is compiled once (`sqlite3_prepare_v2`) and each call
resets, rebinds and steps it.

```lua
local stmt, err = db.prepare(rw, "SELECT name FROM users WHERE age > ?")
if not stmt then error(err) end

local rows, qerr = stmt:query(30)   -- same binding semantics as query
local res, eerr  = stmt:exec(...)   -- for INSERT/UPDATE/DELETE
stmt:close()                        -- finalize now, or let GC do it
```

- `stmt:query(...)` / `stmt:exec(...)` bind the varargs per call, exactly
  like `query` / `exec`; each call runs `sqlite3_reset` +
  `sqlite3_clear_bindings` before binding, and leaves the statement ready
  for the next call.
- **One statement is bound to one connection.** A statement prepared on
  the read-write handle rides the worker pool like every other statement
  on it; one prepared on the read-only handle runs inline, matching that
  handle's semantics.
- **Write SQL on the read-only handle is rejected loudly at prepare time**
  — earlier than the step-time failure of a mis-routed plain exec.
- **Busy discipline:** one statement, one in-flight call. A second
  concurrent call on the same statement fails with `statement is busy`
  instead of corrupting the mid-step state.
- `stmt:close()` finalizes the vendor statement; after it, use fails
  loudly. A statement dropped without `close` is finalized by the
  finalizer.
- Closing a connection with statements still open is safe: every open
  statement is finalized with it, and each surviving statement userdata
  fails loudly afterwards.
- There is no `pool_size` question on this driver: it has no pool.

Is it worth it? For a trivial statement the per-call prepare is
unmeasurable; for a complex or high-rate one it can matter. Read the
SQLite documentation and decide for your own workload — there is no
magic. See `examples/10_db_prepared.lua` for the shape of the API in a
small application.

### Prepare at startup, in one place

The documented pattern is a statement inventory: every statement the
application will run is declared and prepared once when the connection
opens, rebound per call. Five fixed statements prepared at startup beat
five per-call SQL strings re-parsed at every request, and the inventory
keeps the application's SQL visible in one place. This is what the
explicit API exists to enable.

### Same-statement queueing (draft design, not shipped)

Today a second in-flight call on one statement is rejected with
`statement is busy`. The busy flag guards the statement's mid-step state
(the bound parameters, the stepping cursor), but a queued call would
never touch that state: parameters are snapshotted per call, and a queued
call can begin only after the in-flight one completes. The rejected
second call forces every consumer of this shape to hand-roll the same
write queue in application Lua.

The draft proposal:

- a dispatch against one statement while a call on it is in flight parks
  the caller (FIFO, dispatch order) and runs the call on completion;
- `statement is busy` remains only for genuinely invalid states (use
  after close);
- the queue belongs in the driver, beside the statement it protects.

This is a design note, not a shipped contract. Parking a caller from
inside a statement call has open questions (how a parked coroutine yields
and resumes, whether queueing should be per statement or a whole-handle
write chain); see the branch PR for those questions.

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
