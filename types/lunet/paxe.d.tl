global record PaxeConfig
    peer: integer
    channel: integer
end

global record PaxeStats
    rx_total: integer
    rx_ok: integer
    rx_plaintext: integer
    rx_short: integer
    rx_bad_flags: integer
    rx_len_mismatch: integer
    rx_no_peer: integer
    rx_no_epoch: integer
    rx_auth_fail: integer
    tx_total: integer
    tx_standard: integer
    tx_dek: integer
    tx_oversize: integer
end

global record paxe
    OVERHEAD_STANDARD: integer
    OVERHEAD_DEK: integer
    MAX_PAYLOAD_STANDARD: integer
    MAX_PAYLOAD_DEK: integer
    version: function(): string
    init: function(): boolean, string
    set_local_id: function(node_id: integer): boolean, string
    keystore_set: function(peer: integer, epoch: integer, key: string): boolean, string
    keystore_retire: function(peer: integer, epoch: integer): boolean, string
    keystore_clear: function(): boolean
    seal: function(payload: string, to_id: integer, channel: integer): string, string
    open: function(frame: string): string, integer, integer, string
    shutdown: function()
    stats: function(): PaxeStats
    set_fail_policy: function(name: string): boolean
    protect: function(sock: UdpHandle, config: PaxeConfig): boolean
    unprotect: function(sock: UdpHandle): boolean
    is_protected: function(sock: UdpHandle): boolean, integer, integer
end
