global record postgres
    open: function(params: {host: string, port: integer, user: string, password: string, database: string}): userdata, string
    close: function(conn: userdata): string
    query: function(conn: userdata, sql: string, ...: string | number): {any}, string
    exec: function(conn: userdata, sql: string, ...: string | number): {affected_rows: integer, last_insert_id: integer}, string
end
