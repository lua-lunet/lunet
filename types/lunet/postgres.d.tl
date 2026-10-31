global record postgres
    -- pool_size (default 1): connections behind the returned handle,
    -- round-robin. Transactions need one session: open with pool_size = 1,
    -- or checkout a member for the transaction's lifetime.
    -- connect_timeout (integer seconds) and sslmode
    -- ("disable"|"allow"|"prefer"|"require"|"verify-ca"|"verify-full") are
    -- optional at runtime: unset leaves the libpq default untouched.
    open: function(params: {host: string, port: integer, user: string, password: string, database: string, connect_timeout: integer, sslmode: string, pool_size: integer}): userdata, string
    close: function(conn: userdata): string

    -- Exclusive checkout: take one member out of the round-robin rotation
    -- for the duration of a transaction, then return it. The mechanism for
    -- transaction stickiness on a multi-member pool.
    checkout: function(pool: userdata): userdata, string
    release: function(conn: userdata): string

    query: function(conn: userdata, sql: string, ...: string | number): {any}, string
    exec: function(conn: userdata, sql: string, ...: string | number): {affected_rows: integer, last_insert_id: integer}, string

    -- Prepared statements: prepare once (single connection: pool_size = 1
    -- or a checked-out member), execute per call via PQexecPrepared; close
    -- releases the server-side name.
    prepare: function(conn: userdata, sql: string): userdata, string
end

global record postgres_stmt
    query: function(self: userdata, ...: string | number): {any}, string
    exec: function(self: userdata, ...: string | number): {affected_rows: integer, last_insert_id: integer}, string
    close: function(self: userdata): string
end
