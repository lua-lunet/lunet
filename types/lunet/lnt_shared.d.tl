global record LntSharedDict
    get: function(key: string): string | number | boolean, string
    set: function(key: string, value: string | number | boolean, ttl: number): boolean, string
    add: function(key: string, value: string | number | boolean, ttl: number): boolean, string
    replace: function(key: string, value: string | number | boolean, ttl: number): boolean, string
    delete: function(key: string): boolean, string
    incr: function(key: string, delta: number, init: number, ttl: number): number, string
    expire: function(key: string, ttl_secs: number): boolean, string
    ttl: function(key: string): number, string
    flush_all: function()
    flush_expired: function(max: integer): integer
    capacity: function(): integer
    free_space: function(): integer
    close: function(): boolean
end

global record lnt_shared
    open: function(name: string, size_bytes: number): LntSharedDict
    store: function(name: string, size_bytes: number): LntSharedDict
end
