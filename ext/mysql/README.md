# `lunet.mysql`

MySQL driver (libmysqlclient). Either `require("lunet.mysql")` a prebuilt
module straight from a release archive (`lunet/mysql.so`; see the archive
layout in [docs/RELEASE-LAYOUT.md](../docs/RELEASE-LAYOUT.md)), or build it
yourself with `xmake build lunet-mysql`; output is `lunet/mysql.so`.

Placeholders are `?`. Parameters are bound natively via
`mysql_stmt_bind_param`, so values are never concatenated into SQL. There is
deliberately no `db.escape`.

The driver enforces its client-library floor at compile time: it builds
against mysqlclient >= 8.0 (Oracle) or libmariadb >= 3.4 (MariaDB), and an
older client fails the build with a named error. These floors prune legacy
option surface (the removed `MYSQL_OPT_SSL_VERIFY_SERVER_CERT` /
`MYSQL_OPT_SSL_ENFORCE` plaintext fallback) without cutting off access to
older servers: both remain backwards compatible with older servers. The floor
covers the `mysql_stmt_*` API, the option surface
the driver uses, and the non-reconnecting semantics after
`mysql_real_connect`.

| Function | Notes |
|---|---|
| `open(config)` | `host`, `port`, `user`, `password`, `database`, `charset`, optional `connect_timeout`, `pool_size` (default 1), optional TLS keys (see [TLS](#tls)) |
| `close(conn)` | |
| `query(conn, sql, ...)` | returns array of row tables |
| `exec(conn, sql, ...)` | returns `{ affected_rows, last_insert_id }` |
| `query_params` / `exec_params` | same behaviour as the above |
| `checkout(pool)` | check one member out of the pool exclusively: returns a connection handle bound to a single server session, removed from the round-robin rotation until released. The mechanism for transaction stickiness. |
| `release(conn)` | return a checked-out member to the rotation. Idempotent after pool close. |
| `ping(conn)` | liveness probe (`mysql_ping`, one worker hop): probes the checked-out member's session. Returns `ok, err`. No silent reconnect: the driver never sets `MYSQL_OPT_RECONNECT`. |
| `prepare(conn, sql)` | reusable prepared statement; `stmt:query` / `stmt:exec` / `stmt:close`; requires a single member (`pool_size = 1` or a checked-out member) — see [Prepared statements](#prepared-statements) |

### Open settings

`open` accepts a params table with the settings below. Everything except
`host` and friends is optional at runtime; wrong types raise a loud error at
open time rather than being silently ignored.

| Param | Type | Semantics |
|---|---|---|
| `host` | string | default `"localhost"` |
| `port` | integer | default `3306` |
| `user` | string | default `"root"` |
| `password` / `database` | string | defaults `""` |
| `charset` | string | default `"utf8mb4"`, applied via `MYSQL_SET_CHARSET_NAME` |
| `connect_timeout` | integer | seconds libmysqlclient waits before the connect attempt fails; unset leaves the library default untouched |
| `ssl_ca` / `ssl_capath` / `ssl_cert` / `ssl_key` / `ssl_cipher` / `ssl_crl` / `ssl_crlpath` | string | TLS material passed through to the client library (`MYSQL_OPT_SSL_CA` and friends); unset leaves the vendor default untouched. An empty string counts as unset. |
| `tls_version` | string | `"TLSv1.2"` and/or `"TLSv1.3"`, comma-separated (e.g. `"TLSv1.2,TLSv1.3"`, no spaces); anything else fails loudly at open |
| `ssl_mode` | string | **Oracle client only**: `disabled`, `prefer`, `require`, `verify_ca`, `verify_identity` (→ `MYSQL_OPT_SSL_MODE`); on a MariaDB build this key fails loudly — see [TLS](#tls) |
| `ssl_verify_server_cert` | boolean | **MariaDB client only** (→ `MYSQL_OPT_SSL_VERIFY_SERVER_CERT`); on an Oracle build this key fails loudly — see [TLS](#tls) |
| `pool_size` | integer | default `1`; see below |

Passthrough semantics: `connect_timeout` is applied before the handle returns
— the driver sets `MYSQL_OPT_CONNECT_TIMEOUT` on every connection in the pool
before `mysql_real_connect`, so it is in force for the first connection you
touch and for all of them. The driver never invents a value the vendor already
defaults: omit the field and libmysqlclient behaves exactly as its manual
documents.

There is no post-open pragma surface on this handle — no `SET` escape hatch
exposed as an API, no per-session knob. Open-time settings are the entire
contract. (The sqlite3-style read/write split deliberately does not apply to
remote drivers: the server routes read/write traffic itself.)

### TLS

`mysql.open` accepts TLS settings at open time only — the same doctrine as the
postgres driver's `sslmode`: open-time settings are the entire contract, there
are no post-open knobs. Every accepted key is applied via `mysql_options` on
each connection in the pool before `mysql_real_connect`, so the settings govern
the TLS handshake itself. Unset keys leave the client library's default
behaviour untouched — the driver invents nothing.

Both client families accept (plain strings unless noted):

- `ssl_ca`, `ssl_capath`, `ssl_cert`, `ssl_key`, `ssl_cipher`, `ssl_crl`,
  `ssl_crlpath` — passed through to `MYSQL_OPT_SSL_CA`,
  `MYSQL_OPT_SSL_CAPATH`, `MYSQL_OPT_SSL_CERT`, `MYSQL_OPT_SSL_KEY`,
  `MYSQL_OPT_SSL_CIPHER`, `MYSQL_OPT_SSL_CRL`, `MYSQL_OPT_SSL_CRLPATH`.
- `tls_version` — `"TLSv1.2"`, `"TLSv1.3"`, or a comma-separated combination
  (`"TLSv1.2,TLSv1.3"`). Atoms are matched exactly: no whitespace around the
  comma. On Oracle this maps to `MYSQL_OPT_TLS_VERSION`, on MariaDB to
  `MARIADB_OPT_TLS_VERSION`.

The family split is compile-time, by which client library the driver was built
against:

- **Oracle libmysqlclient 8.0:** `ssl_mode` accepts `disabled`, `prefer`,
  `require`, `verify_ca`, `verify_identity` (→ `MYSQL_OPT_SSL_MODE`). The
  library default is `SSL_MODE_PREFERRED`: TLS is used when the server supports
  it, with plaintext fallback otherwise — say `ssl_mode = "require"` to remove
  the fallback. `ssl_verify_server_cert` is **not** an 8.0 option; setting it
  fails loudly — use `ssl_mode = "verify_ca"` / `"verify_identity"` instead.
- **MariaDB Connector/C 3.4:** `ssl_verify_server_cert` (boolean →
  `MYSQL_OPT_SSL_VERIFY_SERVER_CERT`). Connector/C 3.4 verifies the server
  certificate by default (zero-configuration SSL), so the key exists mainly to
  turn verification **off**, or to state the posture explicitly.
  `ssl_mode` is not a MariaDB option; setting it fails loudly.

Validation is loud and happens at open time, before any connection is attempted:
a wrong type or a non-whitelisted value raises an error naming the key. Nothing
is silently ignored, and no default is invented.

Footgun: do not reach for `MYSQL_OPT_SSL_ENFORCE` — despite the name it does
**not** enforce TLS (the vendor documents that the connection falls back to
unencrypted). Require TLS with `ssl_mode = "require"` (Oracle) or by leaving
the MariaDB 3.4 verify-by-default in place, and pin trust with `ssl_ca`.

### `pool_size`

`open` accepts `pool_size` (default **1**): how many server connections sit
behind the returned handle. One statement → one member, picked round-robin
at dispatch; `close` closes all members. MySQL genuinely serves concurrent
client connections, so a wider pool parallelises real work — this is a
feature here, not an escape hatch.

**`mysql_tx` requires one session.** A transaction belongs to the
*connection*; a multi-member pool violates that by construction — the
`SET autocommit=0` … `COMMIT` bracket can land on different sessions and
commit nothing. Either open with `pool_size = 1` (the default), or
`checkout` a member for the whole transaction (below).

## Exclusive checkout

`checkout(pool)` returns a connection handle bound to a single server
session, removed from the pool's round-robin rotation for as long as
it is checked out. Every call on that handle (`query`, `exec`,
`query_params`, `exec_params`, `prepare`) targets that session, so a
transaction stays on one connection even when the pool has many members.

```lua
local mysql = require("lunet.mysql")
local tx = require("lunet.mysql_tx")

local pool = mysql.open({ host = "...", pool_size = 4 })
local conn = mysql.checkout(pool)          -- a dedicated session
local ok, err = tx.transaction(conn, function(t)
    t.exec("DELETE FROM nodes WHERE path = ?", dst)
    local r = t.exec("UPDATE nodes SET path=? WHERE path=? AND version=?",
                     dst, src, version)
    if r.affected_rows == 0 then return nil, "version conflict" end
    return true
end)
mysql.release(conn)                        -- back in the rotation
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

## Prepared statements

`prepare` keeps the vendor statement alive instead of preparing and
destroying it per call: `mysql_stmt_init` + `mysql_stmt_prepare` once,
then per call `mysql_stmt_bind_param` + `mysql_stmt_execute` on the kept
statement. The server re-prepares automatically if statement metadata
changes (for example a table alteration), so a surviving statement stays
correct without caller intervention.

```lua
local stmt, err = mysql.prepare(conn, "SELECT name FROM users WHERE age > ?")
if not stmt then error(err) end

local rows, qerr = stmt:query(30)   -- same binding semantics as query
stmt:close()                        -- mysql_stmt_close
```

- `stmt:query(...)` / `stmt:exec(...)` bind the varargs per call, exactly
  like `query` / `exec`; each call resets and rebinds the kept statement.
- **One statement is bound to one connection.** `prepare` on a pooled
  handle requires `pool_size = 1` (the default) and fails loudly otherwise
  — same doctrine as `mysql_tx`.
- If the connection dies, the statement dies with it: use fails loudly
  (`statement is closed` / `connection is closed`). Closing the connection
  severs every statement still open on it.
- **Busy discipline:** one statement, one in-flight call. A second
  concurrent call on the same statement fails with `statement is busy`
  instead of surfacing as a mid-protocol desync.
- `stmt:close()` releases the vendor statement; after it, use fails
  loudly. A statement dropped without `close` is finalized by the
  finalizer.

Is it worth it? For a trivial statement the per-call prepare is
unmeasurable; for a complex or high-rate one it can matter. Read the
libmysqlclient documentation on the prepared statement API and decide for
your own workload — there is no magic.

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
