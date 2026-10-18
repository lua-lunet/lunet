---@meta

---@class sqlite3
---SQLite driver with the path-keyed handle cache. The binary module
---(lunet.sqlite3core) owns the async I/O; this loader owns the policy:
---open() caches the (rw, ro) pair keyed on the path string, destroy(path)
---closes both and clears the entry, open_raw() bypasses the cache. See
---ext/sqlite3/SQLITE.md.
local db = {}

---Convenience open: returns the cached (rw, ro) pair for this path if one
---exists, otherwise opens a fresh pair and caches it.
---params:
---  path          string  database file; ":memory:" opens a fresh private
---                        in-memory database (never cached; ro is the same
---                        connection and does not enforce read-only)
---  create        string  "WAL" create the file and set journal_mode=WAL;
---                        "NORMAL" create the file, leave the journal mode
---                        at the SQLite default. Without create= the file
---                        must already exist — provisioning is a deployment
---                        act and the driver never makes a sticky change to
---                        a file on its own.
---  busy_timeout  integer ms busy handler on both connections
---  foreign_keys  boolean  PRAGMA foreign_keys on both connections
---  synchronous   string   "OFF"|"NORMAL"|"FULL" on both connections
---The passthroughs apply to both connections before open returns;
---afterwards they are per-connection and last-write-wins via
---db.exec(handle, "PRAGMA ...").
---The ro handle runs queries and execs INLINE on the loop thread — no
---background thread, no yield; a heavy read stalls the loop for its
---duration.
---@param params table Connection parameters
---@return lightuserdata|nil rw Read-write connection, nil on error
---@return lightuserdata|nil ro Read-only connection (reads run inline on the loop thread); nil on error
---@return string|nil err Error message if failed (third return, sqlite3-specific shape)
function db.open(params) end

---Raw open: always opens a fresh (rw, ro, err) pair, bypassing the cache.
---The caller owns the lifetimes and closes each handle with close().
---Takes the same params table as open(); ":memory:" returns the same
---connection as both handles.
---@param params table Connection parameters
---@return lightuserdata|nil rw Read-write connection, nil on error
---@return lightuserdata|nil ro Read-only connection; nil on error
---@return string|nil err Error message if failed
function db.open_raw(params) end

---Close both cached handles for a path and clear the cache entry. No-op
---when there is no entry.
---@param path string The path the handles were opened with
function db.destroy(path) end

---Close a single handle (the open_raw lifetime)
---@param conn lightuserdata The connection to close
---@return string|nil error Error message if failed
function db.close(conn) end

---Execute a SELECT query. On the read-only handle this runs inline on the
---loop thread without yielding; on the read-write handle it is dispatched to
---the worker pool and yields.
---@param conn lightuserdata The connection to execute the query on
---@param sql string The SQL query to execute
---@return table|nil result Array of rows (each row is a table with column names as keys), or nil on error
---@return string|nil error Error message if failed
function db.query(conn, sql) end

---Execute an INSERT, UPDATE, DELETE, or other non-SELECT statement. A write
---mis-routed to the read-only handle fails loudly at step time with
---SQLITE_READONLY and can never commit silently.
---@param conn lightuserdata The connection to execute the statement on
---@param sql string The SQL statement to execute
---@return table|nil result Table with affected_rows and last_insert_id, or nil on error
---@return string|nil error Error message if failed
function db.exec(conn, sql) end

---Execute a SELECT query with an explicit parameter list
---@param conn lightuserdata The connection to execute the query on
---@param sql string The SQL query to execute
---@param params table Array of bind parameters
---@return table|nil result Array of rows, or nil on error
---@return string|nil error Error message if failed
function db.query_params(conn, sql, params) end

---Execute a non-SELECT statement with an explicit parameter list
---@param conn lightuserdata The connection to execute the statement on
---@param sql string The SQL statement to execute
---@param params table Array of bind parameters
---@return table|nil result Table with affected_rows and last_insert_id, or nil on error
---@return string|nil error Error message if failed
function db.exec_params(conn, sql, params) end

---@class sqlite3_stmt
---A reusable prepared statement bound to one connection: prepare once,
---then query/exec per call (the driver resets and rebinds the vendor
---statement each call), then close. A second call while one is in flight
---fails with "statement is busy". Closing the owning connection closes
---every statement still open on it. See ext/sqlite3/SQLITE.md,
---"Prepared statements".
local stmt = {} -- luacheck: ignore

---Run the prepared SELECT with fresh bound parameters. On the read-only
---handle this runs inline on the loop thread; on the read-write handle it
---is dispatched to the worker pool and yields.
---@return table|nil result Array of rows, or nil on error
---@return string|nil error Error message if failed
function stmt.query(...) end

---Run the prepared non-SELECT statement with fresh bound parameters.
---@return table|nil result Table with affected_rows and last_insert_id, or nil on error
---@return string|nil error Error message if failed
function stmt.exec(...) end

---Finalize the vendor statement. After close, use fails loudly. Closing
---an already-closed statement is a no-op.
---@return string|nil error Error message if failed
function stmt.close() end

---Prepare a reusable statement on a connection. The statement is bound to
---this connection for its lifetime. On the read-only handle the prepare
---runs inline and write SQL fails loudly at prepare time. Requires a
---coroutine (lunet.spawn); on the read-write handle the prepare is queued
---to the worker pool and yields.
---@param conn lightuserdata The connection to prepare on
---@param sql string The SQL text (non-empty; ? placeholders)
---@return lightuserdata|nil stmt The prepared statement, or nil on error
---@return string|nil error Error message if failed
function db.prepare(conn, sql) end

return db
