global record sqlite3
    -- open: convenience — caches the (rw, ro) pair keyed on the path string.
    -- open_raw: always fresh, caller-managed lifetimes.
    -- destroy(path): close both cached handles and clear the entry.
    -- params: path is required; create ("WAL"|"NORMAL"), busy_timeout (ms),
    -- foreign_keys (boolean) and synchronous ("OFF"|"NORMAL"|"FULL") are
    -- optional at runtime (all but path may be omitted). Without create=,
    -- the file must already exist. ":memory:" returns one connection as
    -- both handles; ro does not enforce read-only there.
    open: function(params: {path: string, create: string, busy_timeout: integer, foreign_keys: boolean, synchronous: string}): userdata, userdata, string
    open_raw: function(params: {path: string, create: string, busy_timeout: integer, foreign_keys: boolean, synchronous: string}): userdata, userdata, string
    destroy: function(path: string)
    close: function(conn: userdata): string
    query: function(conn: userdata, query: string): {any}, string
    exec: function(conn: userdata, query: string): {affected_rows: integer, last_insert_id: integer}, string

    -- Prepared statements: prepare once, bind per call; one statement is
    -- bound to one connection. Write SQL on the read-only handle fails
    -- loudly at prepare time.
    prepare: function(conn: userdata, sql: string): userdata, string
end

global record sqlite3_stmt
    query: function(self: userdata, ...: any): {any}, string
    exec: function(self: userdata, ...: any): {affected_rows: integer, last_insert_id: integer}, string
    close: function(self: userdata): string
end
