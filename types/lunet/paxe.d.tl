global record paxe
    OVERHEAD_STANDARD: integer
    OVERHEAD_DEK: integer
    VERSION: string
    init: function(): string, string
    shutdown: function()
    set_enabled: function(enabled: boolean)
    is_enabled: function(): boolean
    keystore_set: function(key_id: integer, key_string: string): string, string
    keystore_clear: function()
    set_fail_policy: function(policy: string)
    encrypt: function(plaintext: string, key_id: integer): string, string
    try_decrypt: function(ciphertext: string): string, integer, integer, string
    stats: function(): {rx_total: integer, rx_ok: integer, rx_short: integer, rx_len_mismatch: integer, rx_no_key: integer, rx_auth_fail: integer, rx_reserved_nonzero: integer}
end
