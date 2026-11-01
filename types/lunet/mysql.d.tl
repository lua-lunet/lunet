global record mysql
    -- pool_size (default 1): connections behind the returned handle,
    -- round-robin. Transactions need one session: open with pool_size = 1,
    -- or checkout a member for the transaction's lifetime.
    -- connect_timeout (integer seconds) is optional at runtime: unset
    -- leaves the libmysqlclient default untouched.
    open: function(params: {host: string, port: integer, user: string, password: string, database: string, charset: string, connect_timeout: integer, pool_size: integer}): userdata, string
    close: function(conn: userdata): string

    -- Exclusive checkout: take one member out of the round-robin rotation
    -- for the duration of a transaction, then return it. The mechanism for
    -- transaction stickiness on a multi-member pool.
    checkout: function(pool: userdata): userdata, string
    release: function(conn: userdata): string

    -- Liveness probe: mysql_ping on one member, on a worker hop. No
    -- MYSQL_OPT_RECONNECT, so a dead session reports dead.
    ping: function(conn: userdata): boolean, string
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
