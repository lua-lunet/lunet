---@meta

---@class db
---Unified database module. The backend (MySQL, PostgreSQL, or SQLite3) is selected at compile time.
local db = {}

---Open a database connection
---
---For MySQL/PostgreSQL backends:
---@param params table Connection parameters
--- - host: string (default: "localhost")
--- - port: integer (default: 3306 for MySQL, 5432 for PostgreSQL)
--- - user: string (default: "root" for MySQL, "" for PostgreSQL)
--- - password: string (default: "")
--- - database: string (default: "")
--- - charset: string (MySQL only, default: "utf8mb4")
---
---For SQLite3 backend:
---@param params table Connection parameters
--- - path: string (default: ":memory:")
---
---@return lightuserdata|nil conn The connection handle or nil on error
---@return string|nil error Error message if failed
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

---Escape a string for safe SQL literal inclusion.
---Use this when parameter binding is not available.
---Escapes backslashes and single quotes to prevent SQL injection.
---@param s string The string to escape
---@return string escaped The escaped string safe for SQL literals
function db.escape(s) end

return db
