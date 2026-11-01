---@meta

---@class mysql
local mysql = {}

---Open a MySQL connection
---@param params table The parameters to open the connection
--- - host: The host to connect to
--- - port: The port to connect to
--- - user: The user to connect as
--- - password: The password to use
--- - database: The database to use
--- - charset: The charset to use
--- - connect_timeout: integer? seconds libmysqlclient waits before the connect
---   attempt fails; unset leaves the library default untouched
--- - pool_size: integer? (default 1) connections behind the returned handle,
---   round-robin. Transactions need one session: open with pool_size = 1,
---   or checkout a member for the transaction's lifetime (see checkout).
---@return lightuserdata|nil conn The connection (a pool of pool_size connections) or nil on error
---@return string|nil error Error message if failed
function mysql.open(params) end

---Close a MySQL connection
---@param conn lightuserdata The connection to close (a pool or a checked-out member)
---@return string|nil error Error message if failed
function mysql.close(conn) end

---Check one member out of the pool exclusively: returns a connection handle
---bound to a single server session, removed from the pool's round-robin
---rotation until released. The mechanism for transaction stickiness on a
---multi-member pool. A member checked out this way is itself a single
---connection, so prepare and mysql_tx work on it.
---@param pool lightuserdata The pool handle returned by open
---@return lightuserdata|nil conn The checked-out member handle, or nil on error
---@return string|nil error Error message if failed (e.g. pool exhausted)
function mysql.checkout(pool) end

---Return a checked-out member to the pool's rotation. Idempotent after
---the pool is closed. A double release, or releasing a handle that was
---not checked out, fails loudly.
---@param conn lightuserdata The checked-out member handle
---@return string|nil error Error message if failed
function mysql.release(conn) end

---Liveness probe: mysql_ping on one member, on a worker hop. On a pool
---handle it probes one member (round-robin, skipping checked-out members);
---on a checked-out member it probes that session. The driver never sets
---MYSQL_OPT_RECONNECT, so a dead session reports dead — no silent
---reconnect.
---@param conn lightuserdata The pool or checked-out member handle
---@return boolean ok True when the session is alive
---@return string|nil error Vendor error message when dead
function mysql.ping(conn) end

---Execute a MySQL query
---@param conn lightuserdata The connection to execute the query on
---@param query string The query to execute
---@return table|nil result The result of the query or nil on error
---@return string|nil error Error message if failed
function mysql.query(conn, query) end

---Execute a MySQL query
---@param conn lightuserdata The connection to execute the query on
---@param query string The query to execute
---@return table|nil result The result of the query or nil on error,
---affected_rows: The number of affected rows,
---last_insert_id: The last insert id
---@return string|nil error Error message if failed
function mysql.exec(conn, query) end

---@class mysql_stmt
---A reusable prepared statement bound to one pool member: the vendor
---statement is created once and kept; each query/exec call resets,
---rebinds and executes it; close releases it. The server re-prepares
---automatically when statement metadata changes. A second call while one
---is in flight fails with "statement is busy". Closing the owning
---connection closes every statement still open on it. Requires
---pool_size = 1 (a statement is bound to one connection). See
---ext/mysql/README.md, "Prepared statements".
local stmt = {} -- luacheck: ignore

---Run the prepared SELECT with fresh bound parameters (varargs, same
---binding semantics as query_params).
---@return table|nil result Array of rows, or nil on error
---@return string|nil error Error message if failed
function stmt.query(...) end

---Run the prepared non-SELECT statement with fresh bound parameters.
---@return table|nil result Table with affected_rows and last_insert_id, or nil on error
---@return string|nil error Error message if failed
function stmt.exec(...) end

---Release the vendor statement. After close, use fails loudly. Closing an
---already-closed statement is a no-op.
---@return string|nil error Error message if failed
function stmt.close() end

---Prepare a reusable statement on a connection. Requires a coroutine
---(lunet.spawn); the prepare is queued to the worker pool and yields.
---Requires pool_size = 1.
---@param conn lightuserdata The connection to prepare on
---@param sql string The SQL text (non-empty; ? placeholders)
---@return lightuserdata|nil stmt The prepared statement, or nil on error
---@return string|nil error Error message if failed
function mysql.prepare(conn, sql) end

return mysql
