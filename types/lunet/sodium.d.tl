global record sodium
    BYTES: integer
    BASE64_VARIANT_ORIGINAL: integer
    BASE64_VARIANT_ORIGINAL_NO_PADDING: integer
    BASE64_VARIANT_URLSAFE: integer
    BASE64_VARIANT_URLSAFE_NO_PADDING: integer
    sha256: function(data: string): string, string
    hmac_sha256: function(data: string, key: string): string, string
    random: function(n: integer): string, string
    base64_encode: function(data: string, variant: integer): string, string
    base64_decode: function(data: string, variant: integer): string, string
end
