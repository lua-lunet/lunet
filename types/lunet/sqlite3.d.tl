global record sqlite3
    -- open: convenience — caches the (rw, ro) pair keyed on the path string.
    -- open_raw: always fresh, caller-managed lifetimes.
    -- destroy(path): close both cached handles and clear the entry.
    open: function(params: {path: string}): userdata, userdata, string
    open_raw: function(params: {path: string}): userdata, userdata, string
    destroy: function(path: string)
    close: function(conn: userdata): string
    query: function(conn: userdata, query: string): {any}, string
    exec: function(conn: userdata, query: string): {affected_rows: integer, last_insert_id: integer}, string
end
