global record postgres
    -- pool_size (default 1): connections behind the returned handle,
    -- round-robin; postgres_tx requires the default.
    -- connect_timeout (integer seconds) and sslmode
    -- ("disable"|"allow"|"prefer"|"require"|"verify-ca"|"verify-full") are
    -- optional at runtime: unset leaves the libpq default untouched.
    open: function(params: {host: string, port: integer, user: string, password: string, database: string, connect_timeout: integer, sslmode: string, pool_size: integer}): userdata, string
    close: function(conn: userdata): string
    query: function(conn: userdata, sql: string, ...: string | number): {any}, string
    exec: function(conn: userdata, sql: string, ...: string | number): {affected_rows: integer, last_insert_id: integer}, string
end
