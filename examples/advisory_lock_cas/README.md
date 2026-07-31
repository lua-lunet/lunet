# Advisory Lock CAS Demo (UDP, two nodes)

[中文文档](README-CN.md)

A two-node advisory-lock service over UDP using lunet's coroutine networking.
Clients compare-and-swap (CAS) a lock holder; every write traverses the
**HIGH** node before the **LOW** node, so exactly one winner ever exists for
a contested write, and both nodes always converge.

## What it demonstrates

- The client → node → peer → node → client relay pattern over a single
  libuv loop per process (proven by `test/udp_relay_roundtrip.lua`).
- Deterministic write ordering derived from the nodes' `ip:port` addresses
  (the standard lock-ordering liveness argument: a total order admits no
  cycle).
- msg_id-correlated peer request/reply with timeouts, bounded retries, and
  a CAS-guarded rollback when the peer is unreachable.
- An in-memory lock table with CAS semantics; a text wire protocol you can
  drive with `nc`.

## Layout

| File | Purpose |
|------|---------|
| `node.lua` | The node process (3 UDP sockets, 3 coroutines) |
| `lock.lua` | Pure lock table: `new/get/cas/pack_token` (token = lock_id<<32 \| holder) |
| `codec.lua` | Wire protocol parse/format |
| `pending.lua` | msg_id waiter table for reply correlation |
| `config_gen.lua` | Discovers 2 free ports per node (4 total), writes a Lua config |
| `run_demo.lua` | E2E driver (config → nodes → client → PASS/FAIL) |
| `Makefile` | `test-e2e`, `test-concurrent`, `test-all`, `test-nc`, `clean` |

## Quick start

```bash
xmake build-release   # repo root, once
make -C examples/advisory_lock_cas test-e2e        # sequential GET/SET/stale-token
make -C examples/advisory_lock_cas test-concurrent # barrier-released race: one winner
make -C examples/advisory_lock_cas test-all        # everything incl. timeout/nc
```

## Wire protocol

Plain text, one message per datagram. `lock_id` and `holder` are decimal
`u32`; `token` is 16 lowercase hex chars (`lock_id << 32 | holder`);
`msg_id` is 8 hex chars correlating a reply to its request.

```
GET  /locks/<lock_id> <msg_id>
SET  /locks/<lock_id> <token> <new_holder> <msg_id>
PEER SET /locks/<lock_id> <token> <new_holder> <msg_id>   (node → node)
PEER GET /locks/<lock_id> <msg_id>                        (node → node)

REPLY <msg_id> OK <holder> <token>
REPLY <msg_id> CONFLICT <holder> <token>   (carries the winner's state)
REPLY <msg_id> INVALID                     (e.g. SET with holder=0)
REPLY <msg_id> UNAVAILABLE                 (peer down / timeout)
```

`holder=0` is the "unheld" sentinel: GET on a never-written lock returns
`OK 0 <token>`; SET with `holder=0` is rejected `INVALID`.

## Roles: HIGH and LOW are derived, not configured

Each node binds its client socket, reads its own address with
`udp.getsockname`, and compares `(ip, port)` numerically against the peer's
configured client address. The greater address is **HIGH**; the smaller is
**LOW**. Config labels `n1`/`n2` are entry selectors only — launching both
nodes with the same label is impossible (the second cannot bind the ports),
and identical client addresses abort startup.

- **Client SET → HIGH**: CAS locally; on success propagate to LOW and await
  LOW's apply-OK before replying. On propagation timeout, CAS-guarded
  rollback to the pre-commit state and reply `UNAVAILABLE`.
- **Client SET → LOW**: forward to HIGH, relay HIGH's reply. LOW never
  writes its own state for a client SET — so LOW can never commit a write
  HIGH rejected, and HIGH's CAS is the single serialization point.
- **Propagation → LOW**: applied idempotently (a duplicate/late PEER_SET
  for an already-held state is an OK, not a conflict).

**Liveness.** The blocking graph is a DAG: only LOW's peer_listen handler
never awaits the network (terminal). Every wait is bounded
(`PROP_TIMEOUT_MS=250 ×5`, `FWD_TIMEOUT_MS=500 ×3`) and retries are
bounded, so there is no deadlock and no livelock.

**Rollback limitation (demo simplification).** If HIGH commits write W1 and
a second handler commits W2 on the same lock before W1's propagation times
out, W1's guarded rollback cannot restore the pre-W1 state (the guard sees
W2's token). W1's client gets `UNAVAILABLE`, W2's own outcome decides the
final state. This chained case is out of scope for the demo; the
single-in-flight case rolls back exactly.

## Driving it with nc

Replies are datagrams to the sender's address, which plain `nc` cannot
easily print, so the scripted path fires with `nc` and verifies with a Lua
GET (`make test-nc`). To play by hand, run two terminals:

```bash
# terminal 1: watch the reply arrive (the node logs every request)
make -C examples/advisory_lock_cas test-e2e   # or start nodes via run_demo.lua
# terminal 2:
printf 'SET /locks/1 0000000100000000 42 aa000001\n' | nc -u -w1 127.0.0.1 <n1_client_port>
printf 'GET /locks/1 bb000002\n'                  | nc -u -w1 127.0.0.1 <n2_client_port>
# inspect .tmp/logs/<ts>/node_n*.log for the handler lines
```

## Testing

| Target | What it proves |
|--------|----------------|
| `test-e2e` | sequential SET/GET/stale-token across both nodes |
| `test-concurrent` | barrier-released simultaneous SETs: exactly one OK, one CONFLICT, convergence |
| `test-ordering` | S2: LOW never self-commits when HIGH is down |
| `test-timeout` | SIGSTOP peer: UNAVAILABLE, no wedge, guarded rollback, heal+converge |
| `test-pending` | msg_id pending-table unit (drops unknown/late replies) |
| `test-logs` | node logs are line-buffered while running |
| `test-clean` / `test-quoting` | `make clean` hits repo root; spacey `--output` paths safe |
| `test-validation` | `holder=0` rejected; codec u32 bounds; INVALID/UNAVAILABLE |
| `test-nc` | SET fired via `nc` lands on both nodes |

## Deviations & follow-ups

- **Ports:** two per node (client + peer-listen), four total — per spec.
- **`lnt` / Rust FFI counters:** not used yet; the lock table is pure Lua.
  Tracked as [#131](https://github.com/lua-lunet/lunet/issues/131).
- **`udp.recv` timeout:** implemented in Lua (pending table + poll), not in
  C; a C-level timeout API is a possible future addition, not needed here.
- **Replica reads:** a GET can observe a just-committed remote write one
  propagation later (eventual consistency between nodes, by design).

## See also

- `test/udp_relay_roundtrip.lua` — the go/no-go proof of the relay pattern.
- `.tmp/item00_fix_plan.md` — the rework plan (issue #130).
