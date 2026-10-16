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
---params: { path = "app.db" } (":memory:" cannot be split — use the rw
---handle alone).
---@param params table Connection parameters
---@return lightuserdata|nil rw Read-write connection, nil on error
---@return lightuserdata|nil ro Read-only connection (reads run inline on the loop thread); nil on error
---@return string|nil err Error message if failed (third return, sqlite3-specific shape)
function db.open(params) end

---Raw open: always opens a fresh (rw, ro, err) pair, bypassing the cache.
---The caller owns the lifetimes and closes each handle with close().
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

return db
