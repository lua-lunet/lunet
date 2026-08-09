global type UdpHandle = userdata

global record udp
    bind: function(host: string, port: integer): UdpHandle, string
    send: function(handle: UdpHandle, host: string, port: integer, data: string): boolean, string
    recv: function(handle: UdpHandle): string, string, integer
    close: function(handle: UdpHandle): boolean, string
    getsockname: function(handle: UdpHandle): string, integer, string
end
