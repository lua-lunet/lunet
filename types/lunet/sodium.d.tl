global record sodium
    BYTES: integer
    sha256: function(data: string): string, string
    hmac_sha256: function(data: string, key: string): string, string
    random: function(n: integer): string, string
end
