---@meta

---@class sqlite3_err
---An SQLite driver error: `message` (sqlite3_errmsg text), `code`
---(SQLite primary code) and `extended_code` (sqlite3_extended_errcode)
---when SQLite produced the error, plus `op` naming the operation context
---("open", "query_ro", "query", "exec", "prepare", "route", ...).
---@field message string
---@field code integer|nil
---@field extended_code integer|nil
---@field op string

---@class sqlite3
---SQLite driver. Two logical paths with explicit owners: `ro` runs inline
---on the event loop (transient statement per call, no yield); `rw` is
---owned by one dedicated background worker thread with FIFO dispatch.
---Routing is explicit: query_ro on the ro handle, query/exec on rw.
---Opening one pair gives (rw, ro); the application owns the pair for its
---lifetime and closes it during teardown. See ext/sqlite3/SQLITE.md.
local db = {}

---The raw driver open. Options:
---  path          string  database file; ":memory:" returns one physical
---                        connection for both logical paths (ro does not
---                        enforce read-only there; access serializes
---                        through its owner worker)
---  create        string  omitted: the file must already exist and its
---                        journal mode is untouched; "NORMAL": permit
---                        creation, journal mode unchanged; "WAL": permit
---                        creation, request WAL, and verify SQLite
---                        actually returned wal
---  busy_timeout  integer ms busy handler on each relevant connection
---  foreign_keys  boolean  PRAGMA foreign_keys
---  synchronous   string   "OFF"|"NORMAL"|"FULL"
---  mutex         string   omitted: SQLite's configured default
---                        (unchanged); "nomutex": explicit single-owner
---                        opt-in; "fullmutex": explicit serialized mode
---Unknown option names and invalid values fail loudly. A failed open
---returns no usable partial pair: (nil, nil, err).
---@param params table Connection parameters
---@return lightuserdata|nil rw Read-write connection; nil on failure
---@return lightuserdata|nil ro Read-only connection; nil on failure
---@return sqlite3_err|nil err Error table on failure (third return, sqlite3-specific shape)
function db.open(params) end

---The opt-in helper: opens with synchronous = "NORMAL" as the starting
---default, then copies caller options over it — explicit caller values
---win, other supported options pass through to the raw open. The raw
---open never acquires this default. Unknown options still fail loudly.
---@param path string The database file (or ":memory:")
---@param opts table|nil Remaining open options (create, busy_timeout, foreign_keys, synchronous, mutex)
---@return lightuserdata|nil rw Read-write connection; nil on failure
---@return lightuserdata|nil ro Read-only connection; nil on failure
---@return sqlite3_err|nil err Error table on failure
function db.connect(path, opts) end

---Close a handle. On the rw handle this waits for accepted rw work to
---drain (the close is queued last in the FIFO), finalizes every named
---statement on its owner, and closes the physical connection once. On
---the ro handle it closes inline. Double close is a no-op. After close,
---use fails loudly. Requires a coroutine on the rw handle.
---@param conn lightuserdata The connection to close
---@return nil
function db.close(conn) end

---Run one inline point read on the ro handle: synchronous, no yield, a
---transient statement per call (prepare, bind, step, collect, finalize;
---nothing cached). The loop cannot execute another ro call during it.
---Write SQL is not inspected — SQLite rejects it at step with its
---read-only error. On a :memory: handle the call is dispatched to the
---owner worker so the one physical connection stays single-owner.
---@param conn lightuserdata The read-only connection
---@param sql string The SQL (non-empty; ? placeholders)
---@param ... any Bind parameters
---@return table|nil result Array of row tables, or nil on error
---@return sqlite3_err|nil err Error table on error
function db.query_ro(conn, sql, ...) end

---Run ad-hoc SQL on the rw worker (yields): transient prepare, bind,
---step, finalize. Returns rows — use it for reads and for writes with
---RETURNING. Called with the ro handle it fails loudly with a route
---error.
---@param conn lightuserdata The read-write connection
---@param sql string The SQL (non-empty; ? placeholders)
---@param ... any Bind parameters
---@return table|nil result Array of row tables, or nil on error
---@return sqlite3_err|nil err Error table on error
function db.query(conn, sql, ...) end

---Insert/UPDATE/DELETE or other non-SELECT statements on the rw worker
---(yields). Called with the ro handle it fails loudly with a route
---error.
---@param conn lightuserdata The read-write connection
---@param sql string The SQL statement
---@param ... any Bind parameters
---@return table|nil result Table with affected_rows and last_insert_id, or nil on error
---@return sqlite3_err|nil err Error table on error
function db.exec(conn, sql, ...) end

---Run a SELECT on the rw worker with an explicit binding list (yields).
---@param conn lightuserdata The read-write connection
---@param sql string The SQL query to execute
---@param params table Array of bind parameters
---@return table|nil result Array of rows, or nil on error
---@return sqlite3_err|nil err Error table on error
function db.query_params(conn, sql, params) end

---Run a non-SELECT statement on the rw worker with an explicit binding
---list (yields).
---@param conn lightuserdata The read-write connection
---@param sql string The SQL statement
---@param params table Array of bind parameters
---@return table|nil result Table with affected_rows and last_insert_id, or nil on error
---@return sqlite3_err|nil err Error table on error
function db.exec_params(conn, sql, params) end

---@class sqlite3_stmt
---A named statement of the rw startup inventory: prepare once on the rw
---owner (before serving), then stmt:query / stmt:exec per call. Every
---call snapshots its parameters before dispatch; the worker rebinds and
---resets the statement before the next queued call. Concurrent callers
---of the same statement queue and receive their own result. See
---ext/sqlite3/SQLITE.md, "Named statements".
local stmt = {} -- luacheck: ignore

---Run the named statement as a query with fresh bound parameters on the
---rw worker (yields).
---@return table|nil result Array of rows, or nil on error
---@return sqlite3_err|nil err Error table on error
function stmt.query(...) end

---Run the named statement as a write with fresh bound parameters.
---@return table|nil result Table with affected_rows and last_insert_id, or nil on error
---@return sqlite3_err|nil err Error table on error
function stmt.exec(...) end

---Finalize the vendor statement on its owner (queued through the FIFO).
---After close, use fails loudly. Closing an already-closed statement is
---a no-op.
---@return nil
function stmt.close() end

---Prepare one named statement of the startup inventory on the rw
---connection (yields; the worker compiles the SQL on the owner thread).
---Requires a coroutine. Call it once per statement before the
---application starts serving requests. Called with the ro handle it
---fails loudly with a route error.
---@param conn lightuserdata The read-write connection
---@param sql string The SQL text (non-empty; ? placeholders)
---@return lightuserdata|nil stmt The named statement, or nil on error
---@return sqlite3_err|nil err Error table on error
function db.prepare(conn, sql) end

return db
