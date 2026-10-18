global record mysql
    -- pool_size (default 1): connections behind the returned handle,
    -- round-robin; mysql_tx requires the default.
    -- connect_timeout (integer seconds) is optional at runtime: unset
    -- leaves the libmysqlclient default untouched.
    open: function(params: {host: string, port: integer, user: string, password: string, database: string, charset: string, connect_timeout: integer, pool_size: integer}): userdata, string
    close: function(conn: userdata): string
    query: function(conn: userdata, query: string): {any}, string
    exec: function(conn: userdata, query: string): {affected_rows: integer, last_insert_id: integer}, string

    -- Prepared statements: prepare once (requires pool_size = 1), reset +
    -- rebind + execute per call; the server re-prepares on metadata change.
    prepare: function(conn: userdata, sql: string): userdata, string
end

global record mysql_stmt
    query: function(self: userdata, ...: any): {any}, string
    exec: function(self: userdata, ...: any): {affected_rows: integer, last_insert_id: integer}, string
    close: function(self: userdata): string
end
