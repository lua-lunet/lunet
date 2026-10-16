# SQLite performance model: reads and writes are not symmetric

This note explains how to get the best out of `lunet.sqlite3`, and why the
driver's `open` returns two connections instead of one pool. For the API
reference see the [README](README.md); this page is about the *why*.

## What the tuning showed

A performance-tuning exercise on a fixed-API SQLite-backed HTTP service —
[lua-lunet/twelve-dollar-server-challenge](https://github.com/lua-lunet/twelve-dollar-server-challenge)
— demonstrated the shape of the optimal setup:

- **Separate reads from writes.** One connection owns writes; a second,
  read-only connection serves reads. In WAL mode readers never contend with
  the single writer, so the two paths never block each other.
- **A single thread for writes.** SQLite allows exactly one writer at a
  time; more writer connections buy nothing and only add contention.
- **Concurrent reads on the read-only connection, executed on the loop
  thread.** Reads on a `SQLITE_OPEN_READONLY` connection are pure CPU work
  against the page cache: running them inline — no worker-pool hop, no
  yield, no cross-thread handoff — removed the largest per-request cost on
  the read path. In that tuning the split measured ~4x better p95 across
  the load band than routing every statement through a single pooled
  handle, with zero `SQLITE_BUSY` events in every configuration.

That measured setup is what the driver gives you by default: `open` returns
`(rw, ro, err)` — one writer, one read-only connection whose queries run
inline on the loop thread.

## The failure mode to avoid

The inverse routing — sending a read-heavy load down the `rw` connection —
is potentially suboptimal: every read pays the worker-pool hop and the
cross-thread handoff, and reads queue behind writes on the same connection.
If you see mediocre latency with the driver, check which handle your reads
are on before anything else.

## `pool_size`: an escape hatch, not a performance knob

`open` accepts `pool_size` (default **1**), which sets how many connections
sit behind the `rw` handle. One statement → one member, picked round-robin
at dispatch. With the default, `rw` is exactly one connection — the tuned
setup — and the knob is invisible.

**The expected behaviour is to leave it at the default** and route reads
down the `ro` connection. There is no point increasing the rw pool size
above 1 in order to improve performance: SQLite commits one write at a
time, so a wider writer pool does not parallelise the write path, and it
does nothing for the read path either — reads belong on `ro`, where they
already run concurrently on the loop thread. `ro` is always a single
connection; it does not honour `pool_size`, because read concurrency comes
from coroutines, not connections.

The knob exists purely as an escape hatch for a programmer who does not
want peak performance — who wants to use SQLite in a sloppy mode: code that
assumes a pool of interchangeable connections, a port from a network
driver's habits, a quick-and-dirty script. It is there so such code can be
honest about what it is instead of pretending to be tuned.

Two consequences if you raise it:

- **Transactions lose connection affinity.** `lunet.sqlite3_tx` holds one
  handle for a whole unit of work; with a multi-member pool each statement
  may land on a different connection, so `BEGIN` and `COMMIT` can be
  scattered and commit nothing. Keep `pool_size` at the default if you use
  transactions. This is the documented rule that a transaction belongs to
  the *connection*, not the coroutine — a pool violates it by construction.
- **Writes still serialise.** WAL or not, SQLite allows one writer at a
  time; the pool only lets sloppy code run at all, not run wider.

## Summary

| Setup | rw pool | reads | Writes | Reads |
|---|---|---|---|---|
| Default (tuned) | 1 connection | `ro` handle, inline on the loop thread | single writer, worker pool | concurrent, uncontended |
| Escape hatch (sloppy) | `pool_size` > 1, round-robin | wherever the code sends them | still one-at-a-time at SQLite | pay the worker hop |
