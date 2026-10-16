---@meta

---@class sqlite3
---SQLite driver. `open` returns two connections: a read-write handle
---(worker-pool dispatch, as always) and a read-only handle whose queries run
---inline on the loop thread. See ext/sqlite3/README.md.
local db = {}

---Open a database file.
---@param params table { path = "app.db" } (":memory:" cannot be split — use the rw handle alone)
---@return lightuserdata|nil rw Read-write connection, nil on error
---@return lightuserdata|nil ro Read-only connection (reads run inline on the loop thread); nil on error
---@return string|nil err Error message if failed (third return, sqlite3-specific shape)
function db.open(params) end

---Close a connection (either handle)
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
