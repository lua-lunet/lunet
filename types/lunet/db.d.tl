global type Conn = userdata

-- Legacy compile-time-selected surface. The sqlite3 driver has its own
-- record now (types/lunet/sqlite3.d.tl): its open returns TWO connections
-- (rw, ro) plus the error in the third position, and takes an optional
-- pool_size (default 1, escape hatch). The network backends keep
-- (conn, err). This record keeps the network shape; the {path} variant is
-- annotated as the sqlite3 3-return split.
global record db
    open: function(params: {host: string, port: integer, user: string, password: string, database: string, charset: string}): Conn, string
    open: function(params: {path: string, pool_size: integer}): Conn, Conn, string
    close: function(conn: Conn): string
    query: function(conn: Conn, sql: string): {any}, string
    exec: function(conn: Conn, sql: string): {affected_rows: integer, last_insert_id: integer}, string
end
