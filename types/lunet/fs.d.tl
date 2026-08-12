global record fs
    open: function(path: string, mode: string): integer, string
    -- error-only: returns nil on success, error string on failure
    close: function(fd: integer): string
    stat: function(path: string): {any}, string
    read: function(fd: integer, size: integer): string, string
    write: function(fd: integer, data: string): string
    scandir: function(path: string): {string}, string
end
