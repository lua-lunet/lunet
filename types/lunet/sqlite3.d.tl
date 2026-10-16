global record sqlite3
    -- open: pool_size (default 1) sets how many connections sit behind the
    -- rw handle (round-robin). Escape hatch, never for performance; ro is
    -- always single. See ext/sqlite3/SQLITE.md.
    open: function(params: {path: string, pool_size: integer}): userdata, userdata, string
    close: function(conn: userdata): string
    query: function(conn: userdata, query: string): {any}, string
    exec: function(conn: userdata, query: string): {affected_rows: integer, last_insert_id: integer}, string
end
