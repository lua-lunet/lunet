---@meta

---@class db
---Unified database module. The backend (MySQL, PostgreSQL, or SQLite3) is selected at compile time.
local db = {}

---Connection parameters for MySQL/PostgreSQL backends.
---@class DbNetParams
---@field host string Host to connect to (default: "localhost")
---@field port integer Port to connect to (default: 3306 for MySQL, 5432 for PostgreSQL)
---@field user string User to connect as (default: "root" for MySQL, "" for PostgreSQL)
---@field password string Password to use (default: "")
---@field database string Database to use (default: "")
---@field charset string Charset to use (MySQL only, default: "utf8mb4")
---@field pool_size integer Connections behind the returned handle, round-robin
---(default 1; postgres_tx/mysql_tx require the default)

---Connection parameters for the SQLite3 backend.
---The sqlite3 driver's open returns TWO connections: prefer
---types/lunet/sqlite3.lua, which annotates the (rw, ro, err) shape and the
---optional pool_size escape hatch (default 1).
---@class DbFileParams
---@field path string Database file path (default: ":memory:")
---@field pool_size integer Connections behind the rw handle, round-robin
---(sqlite3 only, default 1; escape hatch, not for performance)

---Open a database connection
---@param params DbNetParams|DbFileParams Connection parameters (shape depends on the compiled backend)
---@return lightuserdata|nil conn The connection handle or nil on error
---@return lightuserdata|nil ro_readonly Read-only connection (sqlite3 backend only); nil on error or network backends
---@return string|nil error Error message if failed
---(sqlite3 backend: third return; network backends: second return)
function db.open(params) end

---Close a database connection
---@param conn lightuserdata The connection to close
---@return string|nil error Error message if failed
function db.close(conn) end

---Execute a SELECT query
---@param conn lightuserdata The connection to execute the query on
---@param sql string The SQL query to execute
---@return table|nil result Array of rows (each row is a table with column names as keys), or nil on error
---@return string|nil error Error message if failed
function db.query(conn, sql) end

---Execute an INSERT, UPDATE, DELETE, or other non-SELECT statement
---@param conn lightuserdata The connection to execute the statement on
---@param sql string The SQL statement to execute
---@return table|nil result Table with affected_rows and last_insert_id, or nil on error
---@return string|nil error Error message if failed
function db.exec(conn, sql) end

return db
