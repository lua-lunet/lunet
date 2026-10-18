---@meta

---@class postgres
local postgres = {}

---Open a PostgreSQL connection.
---@param params table Connection parameters
--- - host: string? (default "localhost")
--- - port: integer? (default 5432)
--- - user: string? (default "")
--- - password: string? (default "")
--- - database: string? (default "")
--- - connect_timeout: integer? seconds libpq waits before the connect attempt
---   fails; unset leaves the libpq default untouched
--- - sslmode: string? one of "disable"|"allow"|"prefer"|"require"|"verify-ca"|"verify-full";
---   unset leaves the libpq default untouched
--- - pool_size: integer? (default 1) connections behind the returned handle,
---   round-robin; postgres_tx requires the default
---@return lightuserdata|nil conn The connection handle (a pool of pool_size connections), or nil on error
---@return string|nil error Error message if failed
---@usage
---```lua
---local pg = require("lunet.postgres")
---local conn, err = pg.open({ host = "127.0.0.1", database = "testdb" })
---if not conn then error(err) end
---```
function postgres.open(params) end

---Close a PostgreSQL connection.
---@param conn lightuserdata The connection handle
---@return string|nil error Error message if failed
function postgres.close(conn) end

---Execute a SELECT query with optional bound parameters.
---
---Placeholders are `$1`, `$2`, ... (Postgres-style).
---A statement with bound parameters must be a single command.
---@param conn lightuserdata The connection handle
---@param sql string SQL query with optional $n placeholders
---@param ... string|number Bound parameter values
---@return table|nil rows Array of row tables (each row maps column name to value), or nil on error
---@return string|nil error Error message if failed
function postgres.query(conn, sql, ...) end

---Execute an INSERT, UPDATE, DELETE, or other non-SELECT statement with optional bound parameters.
---
---Placeholders are `$1`, `$2`, ... (Postgres-style).
---A statement with bound parameters must be a single command (libpq extended query protocol).
---Statements with *no* parameters may contain several commands separated by `;`,
---but only the last command's rows and affected_rows are returned.
---@param conn lightuserdata The connection handle
---@param sql string SQL statement with optional $n placeholders
---@param ... string|number Bound parameter values
---@return table|nil result { affected_rows = integer, last_insert_id = integer }, or nil on error
---@return string|nil error Error message if failed
function postgres.exec(conn, sql, ...) end

---@class postgres_stmt
---A reusable prepared statement bound to one pool member: the SQL is
---prepared once under a unique session-scoped name (PQprepare); each
---query/exec call executes it via PQexecPrepared with fresh parameters;
---close releases the server-side definition with PQclosePrepared. If the
---connection dies, the statement dies with the session: use fails loudly.
---A second call while one is in flight fails with "statement is busy".
---Requires pool_size = 1 (a statement is bound to one connection). See
---ext/postgres/README.md, "Prepared statements".
local stmt = {} -- luacheck: ignore

---Run the prepared SELECT with fresh bound parameters (varargs, same
---binding semantics as query).
---@return table|nil rows Array of row tables, or nil on error
---@return string|nil error Error message if failed
function stmt.query(...) end

---Run the prepared non-SELECT statement with fresh bound parameters.
---@return table|nil result { affected_rows = integer, last_insert_id = integer }, or nil on error
---@return string|nil error Error message if failed
function stmt.exec(...) end

---Release the server-side statement (PQclosePrepared, one worker hop).
---After close, use fails loudly. Closing an already-closed statement is a
---no-op. A statement dropped without close leaves its server-side
---definition allocated until the session ends.
---@return string|nil error Error message if failed
function stmt.close() end

---Prepare a reusable statement on a connection. Requires a coroutine
---(lunet.spawn); the prepare is queued to the worker pool and yields.
---Requires pool_size = 1.
---@param conn lightuserdata The connection to prepare on
---@param sql string The SQL text (non-empty; $n placeholders)
---@return lightuserdata|nil stmt The prepared statement, or nil on error
---@return string|nil error Error message if failed
function postgres.prepare(conn, sql) end

return postgres
