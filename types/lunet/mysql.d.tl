global record mysql
    -- pool_size (default 1): connections behind the returned handle,
    -- round-robin. Transactions need one session: open with pool_size = 1,
    -- or checkout a member for the transaction's lifetime.
    -- connect_timeout (integer seconds) is optional at runtime: unset
    -- leaves the libmysqlclient default untouched.
    -- TLS passthrough (open-time only, mirroring the postgres sslmode
    -- design): ssl_ca/ssl_capath/ssl_cert/ssl_key/ssl_cipher/ssl_crl/
    -- ssl_crlpath/tls_version are strings, unset leaves the vendor default.
    -- tls_version whitelists "TLSv1.2" and/or "TLSv1.3", comma-separated.
    -- ssl_mode ("disabled"/"prefer"/"require"/"verify_ca"/"verify_identity")
    -- is Oracle-client only; ssl_verify_server_cert (boolean) is
    -- MariaDB-client only (3.4 verifies by default) — the other family
    -- fails loudly on each. Validation errors raise before any connect.
    open: function(params: {host: string, port: integer, user: string, password: string, database: string, charset: string, connect_timeout: integer, ssl_ca: string, ssl_capath: string, ssl_cert: string, ssl_key: string, ssl_cipher: string, ssl_crl: string, ssl_crlpath: string, tls_version: string, ssl_mode: string, ssl_verify_server_cert: boolean, pool_size: integer}): userdata, string
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
