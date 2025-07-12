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
---@return lightuserdata|nil conn The connection or nil on error
---@return string|nil error Error message if failed
function mysql.open(params) end

---Close a MySQL connection
---@param conn lightuserdata The connection to close
---@return string|nil error Error message if failed
function mysql.close(conn) end

---Execute a MySQL query
---@param conn lightuserdata The connection to execute the query on
---@param query string The query to execute
---@return table|nil result The result of the query or nil on error
---@return string|nil error Error message if failed
function mysql.query(conn, query) end

---Execute a MySQL query
---@param conn lightuserdata The connection to execute the query on
---@param query string The query to execute
---@return table|nil result The result of the query or nil on error, affected_rows: The number of affected rows, last_insert_id: The last insert id
---@return string|nil error Error message if failed
function mysql.exec(conn, query) end

return mysql
