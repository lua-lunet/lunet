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
---@return lightuserdata|nil conn The connection handle, or nil on error
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

return postgres
