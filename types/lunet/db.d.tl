global type Conn = userdata

global record db
    open: function(params: {host: string, port: integer, user: string, password: string, database: string, charset: string} | {path: string}): Conn, string
    close: function(conn: Conn): string
    query: function(conn: Conn, sql: string): {any}, string
    exec: function(conn: Conn, sql: string): {affected_rows: integer, last_insert_id: integer}, string
end
