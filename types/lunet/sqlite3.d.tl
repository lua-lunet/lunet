global record sqlite3_err
    message: string
    code: integer
    extended_code: integer
    op: string
end

global record sqlite3
    -- open: the raw driver open. create omitted => the file must exist and
    -- its journal mode is untouched; "NORMAL" permits creation;
    -- "WAL" permits creation, requests WAL and verifies it. Passes
    -- busy_timeout (ms), foreign_keys (bool), synchronous
    -- ("OFF"|"NORMAL"|"FULL") through. mutex omitted === SQLite's
    -- configured default; "nomutex" / "fullmutex" are explicit choices.
    -- Unknown option names and invalid values fail loudly. Failure shape:
    -- (nil, nil, err); success: (rw, ro, nil).
    open: function(params: {path: string, create: string, busy_timeout: integer, foreign_keys: boolean, synchronous: string, mutex: string}): userdata, userdata, sqlite3_err

    -- connect: the opt-in helper — starts at synchronous = "NORMAL",
    -- caller options override; the raw open gets no helper default.
    connect: function(path: string, opts: {create: string, busy_timeout: integer, foreign_keys: boolean, synchronous: string, mutex: string}): userdata, userdata, sqlite3_err

    close: function(conn: userdata): nil

    -- query_ro: inline on the ro handle (no yield, transient statement per
    -- call). query/exec run on the rw worker (yield): rows vs write
    -- metadata. query_params/exec_params: same with an explicit binding
    -- table. Checkpoint: with the ro handle, query/exec/query_params/
    -- exec_params/prepare fail loudly with a route error table.
    query_ro: function(conn: userdata, sql: string, ...: any): {any}, sqlite3_err
    query: function(conn: userdata, sql: string, ...: any): {any}, sqlite3_err
    exec: function(conn: userdata, sql: string, ...: any): {affected_rows: integer, last_insert_id: integer}, sqlite3_err
    query_params: function(conn: userdata, sql: string, params: {any}): {any}, sqlite3_err
    exec_params: function(conn: userdata, sql: string, params: {any}): {affected_rows: integer, last_insert_id: integer}, sqlite3_err

    -- prepare: one named statement of the startup inventory, compiled by
    -- the rw worker. Concurrent callers of the same named statement queue;
    -- every call snapshots its own parameters. No statement pool.
    prepare: function(conn: userdata, sql: string): userdata, sqlite3_err
end

global record sqlite3_stmt
    query: function(self: userdata, ...: any): {any}, sqlite3_err
    exec: function(self: userdata, ...: any): {affected_rows: integer, last_insert_id: integer}, sqlite3_err
    close: function(self: userdata): nil
end
