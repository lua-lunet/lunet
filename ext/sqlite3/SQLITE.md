# `lunet.sqlite3`

SQLite driver. Either `require("lunet.sqlite3")` a prebuilt module straight
from a release archive (`lunet/sqlite3.lua` + `lunet/sqlite3core.so`; see the
archive layout in [docs/RELEASE-LAYOUT.md](../docs/RELEASE-LAYOUT.md)), or
build it yourself with `xmake build lunet-sqlite3`. This page is the complete
reference: the API, the two ownership paths, the open contract, and the
performance model.

Placeholders are `?`. Parameters are bound natively via `sqlite3_bind_*`, so
values are never concatenated into SQL. There is deliberately no `db.escape`.

## Ownership and routing

The driver has two logical paths, each with one owner, and the application
chooses where work runs:

- **`ro` is owned by Lunet's single event-loop thread.**
  `query_ro(ro, sql, ...)` executes synchronously, inline, without yielding.
  The loop cannot execute another `ro` call concurrently with that call:
  other coroutines only get execution when control returns to the scheduler,
  and many requests in flight never mean two SQLite calls executing at once
  on this connection. Every call is a *transient statement*: prepare, bind,
  step, collect, finalize — nothing is cached. `ro` is for short, measured
  point reads only; a heavy read stalls the loop for its duration. There is
  deliberately no named statement cache and no statement pool on this path.
- **`rw` is owned by one dedicated background worker thread.** It handles
  writes and heavier reads that should release the loop while SQLite runs.
  Calling `rw` suspends the calling coroutine; the worker completes the
  operation, and the runtime resumes the coroutine with its result.
  Work across the whole `rw` connection is serialized in FIFO dispatch
  order. There is one `rw` connection and one owning worker — no connection
  pool, no statement pool.

Routing is explicit and never inferred from SQL prefixes:

| Call | Connection | Runs where |
|---|---|---|
| `query_ro(ro, sql, ...)` | `ro` | inline on the loop thread |
| `query(rw, sql, ...)` | `rw` | on the dedicated worker, yields |
| `exec(rw, sql, ...)` | `rw` | on the dedicated worker, yields |
| `query_params` / `exec_params` | `rw` | on the dedicated worker, yields |
| `prepare(rw, sql)` | `rw` | on the dedicated worker, yields |

The `rw` connection is also the general connection — it reads too. The
route calls are policed: `query`, `query_params`, `exec`, `exec_params`
and `prepare` called with the `ro` handle fail loudly with a route error
(op `"route"`, message directs to `query_ro`) — the routing contract is
the API, not a hint. And a write sent to the file-backed `ro` handle
*through `query_ro`* — the call that actually runs on the `ro` connection
— is rejected by SQLite itself at step with its read-only error
(`code = 8`, `SQLITE_READONLY`) and can never commit silently. A `ro`
read sees the committed state at the moment the read starts; route
consistency-critical reads through `rw` (each call there is a fresh read,
issued after the write call returns, so it is current).

The SQLite mutex mode does not establish FIFO scheduling and is not a
substitute for this ownership contract: it only sets how SQLite contends
with its own locks. See [Mutex mode](#mutex-mode).

## Surface

| Function | Notes |
|---|---|
| `open(config)` | the raw driver open; see [The open contract](#the-open-contract). Returns `(rw, ro, nil)` or `(nil, nil, err)` |
| `connect(path, opts)` | the opt-in helper: `synchronous = "NORMAL"` default, caller options win; see [The helper](#the-helper) |
| `close(conn)` | on `rw`: drains accepted work, then closes; on `ro`: closes inline |
| `query_ro(conn, sql, ...)` | inline on `ro`; transient statement per call |
| `query(conn, sql, ...)` | rows, on `rw` — also for writes with `RETURNING` |
| `exec(conn, sql, ...)` | `{ affected_rows, last_insert_id }`, on `rw` |
| `query_params` / `exec_params` | same as above with an explicit binding list |
| `prepare(conn, sql)` | named statement for the startup inventory; yields. `stmt:query` / `stmt:exec` / `stmt:close` — see [Named statements](#named-statements) |

Errors are tables — see [Errors](#errors).

All calls must run inside a coroutine spawned via `lunet.spawn`.

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
--    create = "WAL"    -> creates the file, requests WAL, and verifies
--                         SQLite actually returned WAL (a filesystem that
--                         cannot host WAL fails the open loudly).
--    create = "NORMAL" -> creates the file, journal mode stays at the
--                         SQLite default.
--    create omitted    -> the file must already exist and its journal
--                         mode is left untouched.
--    There is no "un-WAL" here: WAL is persistent for the file, and the
--    driver never changes the mode of an existing file on its own. On an
--    existing file create=WAL re-issues the pragma (idempotent).

-- 3. Passthroughs, applied to each relevant connection:
local rw, ro, err = db.open({
    path = "app.db", create = "WAL",
    busy_timeout = 3000,        -- ms: the busy handler on each connection
    foreign_keys = true,        -- PRAGMA foreign_keys
    synchronous  = "NORMAL",    -- durability trade; see the helper below
})

-- 4. Unit tests: swap the path for :memory: and the same code shape runs.
--    One physical connection is returned for both logical paths, and its
--    access is serialized through its owner (the rw worker). ro does not
--    enforce read-only there — :memory: is a testing substitution, not a
--    file-backed read-only guarantee.
local rw, ro, err = db.open({ path = ":memory:" })
```

```lua
-- 5. Explicit mutex mode (optional; the default is left unchanged):
local rw, ro, err = db.open({ path = "app.db", mutex = "nomutex" })
```

### Mutex mode

`mutex` selects the connection threading mode of the opened connections:

- Omitted: SQLite's configured default for the build — usually the
  serialized mode. Nothing changes.
- `mutex = "nomutex"`: SQLite's multi-thread mode. An **explicit opt-in
  declaring the caller's single-owner, no-concurrent-use contract** — under
  this driver's ownership model (one loop-thread `ro`, one worker `rw`)
  every connection has exactly one owner at a time, so the per-call mutex
  is pure overhead. Keep the default unless you know you want this.
- `mutex = "fullmutex"`: SQLite's fully-serialized mode, applied
  explicitly.

Mutex mode is set per connection at open time (the `SQLITE_OPEN_NOMUTEX` /
`SQLITE_OPEN_FULLMUTEX` open flags); the driver never flips a process-wide
SQLite configuration on behalf of an embedding runtime.

### Unknown options

Unknown option names and invalid values fail clearly — they are loud
errors, never silently ignored. The accepted option set is: `path`,
`create`, `busy_timeout`, `foreign_keys`, `synchronous`, `mutex`.

A failed open returns no usable partial handle pair and releases everything
it opened: both handles are `nil` and the error is the third return.

### The helper

```lua
local db = assert(require("lunet.sqlite3"))
local rw, ro, err = db.connect("app.db", { create = "WAL" })
```

`connect(path, opts)` wraps `open` for applications: it starts from
`synchronous = "NORMAL"` and then copies caller options over that default —
an explicit caller value wins, and every other supported option passes
through unchanged. The raw `open` itself never acquires the helper's
default; a driver that wants another setting opts in explicitly.

The passthroughs are per-connection and last-write-wins — after open, tune
either handle independently:

```lua
db.exec(rw, "PRAGMA busy_timeout = 5000")  -- rw only; ro keeps the open value
```

## Reads and writes

```lua
local db = require("lunet.sqlite3")

lunet.spawn(function()
  local rw, ro, err = db.open({ path = "app.db", create = "WAL" })
  if not rw then error(err.message) end

  -- Writes go to rw (the dedicated worker)...
  assert(db.exec(rw, "INSERT INTO t VALUES (?)", 1))

  -- ...short point reads go to ro: inline on the loop thread,
  -- no yield, a transient statement per call.
  local rows = assert(db.query_ro(ro, "SELECT * FROM t"))

  db.close(rw)   -- drains accepted rw work, then closes
  db.close(ro)
end)
```

- `rw` — the read-write connection: one dedicated background worker thread,
  FIFO dispatch. It is also the general connection and the only one that
  writes.
- `ro` — a second connection opened with `SQLITE_OPEN_READONLY` for point
  reads. If you discard it,
  `local rw, _ = db.open({ path = "app.db" })`
  (`_` is Lua convention, not a language feature) and every call runs on
  `rw`.

## Named statements

`prepare` keeps the vendor statement alive instead of compiling per call:
the SQL is compiled once (`sqlite3_prepare_v2`) by the worker, and each
call resets, rebinds and steps it.

```lua
local stmt, err = db.prepare(rw, "SELECT name FROM users WHERE age > ?")
if not stmt then error(err.message) end

local rows, qerr = stmt:query(30)   -- same binding semantics as query
local res, eerr  = stmt:exec(...)   -- for INSERT/UPDATE/DELETE
stmt:close()                        -- finalize on the owner now, or let GC
```

Named statements are declared as one **startup inventory**: the application
prepares them on the `rw` connection before it serves requests, and each
statement is bound to that connection for its lifetime.

- Every call snapshots its parameters before dispatch; the worker executes
  the snapshot on the owner, then resets the statement before the next
  queued call.
- **Concurrent callers of the same statement wait their turn and receive
  their own result.** Ordinary concurrent use never produces a busy-statement
  error — the FIFO queue is the scheduling, not a SQLite lock.

## Errors

Errors are Lua tables that preserve SQLite's message, primary and extended
codes, and the operation context:

```lua
rows, err = db.query_ro(ro, "SELECT * FROM nope")
-- err = {
--   message       = "no such table: nope",   -- sqlite3_errmsg()
--   code          = 1,                        -- primary code (SQLITE_ERROR)
--   extended_code = 1,                        -- sqlite3_extended_errcode()
--   op            = "query_ro",               -- operation context
-- }
```

`code` and `extended_code` are present when SQLite produced the error
(otherwise only `message` and `op` — for example a route violation or a
closed connection). Read `err.message`, never `tostring(err)`.

Key cases:

- A write sent to the file-backed `ro` handle *through `query_ro`* reports
  SQLite's read-only error at step (`code = 8`, `SQLITE_READONLY`,
  `extended_code` present). The other calls (query/params/exec/prepare)
  called with the `ro` handle fail with a route violation (`op = "route"`)
  — routing is by call, and the wrong call never reaches SQLite.
- A failed statement is a **result to the caller, never a worker shutdown**:
  the connection stays usable, and a succeeding call after a failed one
  still works.
- A failed `prepare` in the startup inventory returns `(nil, err)` — release
  the pair and fix the inventory before serving.

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

if not ok and err.poisoned then db.close(rw) end
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
- **`query`/`exec` bind parameters.** `db.exec(rw, "INSERT INTO t VALUES (?,?)",
  a, b)` binds `a` and `b` just like `exec_params`.
- **The routing split needs a file path.** `:memory:` cannot be split: the
  two logical paths alias one physical connection there, and its access is
  serialized through its owner (the `rw` worker). Pass a file path whenever
  you intend to use the inline `ro` path; on `:memory:` simply use `rw`.

## Values

Binding: `nil` → NULL, numbers → integer or double (doubles that represent
exact integers bind as integers), booleans → 0/1, strings → text. Columns
preserve what SQLite produced per cell: `NULL` reads as Lua `nil`,
integers as Lua numbers, reals as Lua numbers, text as Lua strings, and
blobs as Lua strings carrying the exact bytes (length-preserved, embedded
NULs included). The per-cell SQLite type drives the conversion — a column
holding different types across rows reads correctly row by row.

## Lifetimes and teardown

The application owns its opened pair for its lifetime and closes it during
teardown. There is no process-wide, path-keyed connection cache: opening
twice opens two independent pairs, and closing one does not affect the
other.

- `close(rw)` waits for accepted `rw` work to drain (FIFO — the close is
  queued behind it), finalizes every statement of the inventory on its
  owner, and closes the physical connection once. After it, further use
  fails loudly.
- `close(ro)` closes inline.
- A statement dropped without `stmt:close()` is finalized when the GC
  collects it; closing the connection finalizes everything still open on
  it.

## The performance model

A performance-tuning exercise on a fixed-API SQLite-backed HTTP service —
[lua-lunet/twelve-dollar-server-challenge](https://github.com/lua-lunet/twelve-dollar-server-challenge)
— demonstrated the shape of the optimal setup, and this driver is that
shape:

- **Separate reads from writes.** One connection owns writes; the read-only
  connection serves point reads. In WAL mode readers never contend with the
  single writer, so the two paths never block each other.
- **A single thread for writes.** SQLite allows exactly one writer at a
  time; more writer connections buy nothing and only add contention.
- **Short reads inline on the loop thread.** The submission measured the
  transient per-call preparation of short inline reads and kept it: a fast
  point read occupies the event loop only for its own duration, with no
  worker hop, no yield, no cross-thread handoff. In that tuning the split
  measured ~4x better p95 across the load band than routing every statement
  through a single pooled handle, with zero `SQLITE_BUSY` events in every
  configuration.
- **Heavier work off the loop.** Reads too slow for the event loop belong
  on `rw`, where the FIFO worker serializes them behind writes without
  ever blocking the loop — accept the extra hop for exactly that work.

The failure mode to avoid: the inverse routing — sending a read-heavy load
down the `rw` connection — is potentially suboptimal: every read pays the
worker hop and the cross-thread handoff, and reads queue behind writes
on the same connection. If you see mediocre latency, check which handle
your reads are on before anything else.

There is deliberately **no pooling on this driver**. The single write path
IS the design: to go faster, route point reads to `query_ro` — never widen
a pool.

## How the ownership contract is verified

SQLite needs no server, so this is committed test material:

- `spec/sqlite3_spec.lua` — surface, option and routing validation.
- `test/smoke_sqlite3_contract.lua` — the live contract: inline `ro`
  without yielding, `rw` suspension and resume with FIFO order and
  distinct results for concurrent same-name callers, option defaults and
  overrides, startup-failure cleanup, fail-then-succeed, and close-drain.

Run them after `xmake build lunet-sqlite3 && xmake build-release`:

```
xmake test
LUNET_BIN=$(find build -path '*/release/lunet-run' -type f | head -1)
"$LUNET_BIN" test/smoke_sqlite3_contract.lua
```

`test/smoke_sqlite3_tx.lua` pins the transaction wrapper's control flow.
