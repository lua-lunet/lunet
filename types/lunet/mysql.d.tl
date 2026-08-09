global record mysql
    open: function(params: {host: string, port: integer, user: string, password: string, database: string, charset: string}): userdata, string
    close: function(conn: userdata): string
    query: function(conn: userdata, query: string): {any}, string
    exec: function(conn: userdata, query: string): {affected_rows: integer, last_insert_id: integer}, string
end
