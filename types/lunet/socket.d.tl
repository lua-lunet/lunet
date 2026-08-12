global type Handle = userdata

global record socket
    listen: function(protocol: string, host: string, port: integer): Handle, string
    accept: function(listener: Handle): Handle, string
    getpeername: function(client: Handle): string, string
    read: function(client: Handle): string, string
    -- error-only: returns nil on success, error string on failure
    write: function(client: Handle, data: string): string
    close: function(handle: Handle)
    set_read_buffer_size: function(size: integer)
    connect: function(host: string, port: integer): Handle, string
end
