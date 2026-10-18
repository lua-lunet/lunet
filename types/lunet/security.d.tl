global record security
    record crypto
        -- HMAC-SHA-256 over lunet.sodium: a 32-byte key is used as-is,
        -- any other non-empty key is first reduced to 32 bytes with
        -- SHA-256 (deterministic subkey derivation — hashed, never
        -- truncated or zero-padded). Returns the raw 32-byte tag, or
        -- nil plus a message on operational failure (libsodium init).
        sign: function(data: string, key: string): string, string
        -- Constant-time verify: computes the expected tag and compares
        -- it through an accumulated XOR difference. A sig of any other
        -- length than 32 bytes is false.
        verify: function(data: string, key: string, sig: string): boolean
        -- Unpadded base64url (the JWT profile) over lunet.sodium's
        -- URLSAFE variant. Malformed input raises with the library's
        -- diagnostic, like lunet.sodium itself.
        b64url_encode: function(data: string): string, string
        b64url_decode: function(data: string): string, string
    end

    record jwt
        -- HS256 encode: header fixed at {alg = "HS256", typ = "JWT"};
        -- opts.expires_in (positive integer seconds) injects exp on a
        -- copy of the payload; without it the payload passes through
        -- unchanged. Malformed arguments raise.
        encode: function(payload: {string: any}, secret: string, opts: {string: any}): string, string
        -- HS256 decode: verifies the signature constant-time before
        -- parsing, refuses any header alg but HS256, enforces exp when
        -- present (a token without exp never expires). Content failures
        -- return nil plus a string naming the kind: malformed / sig /
        -- exp. Malformed arguments (bad secret) raise.
        decode: function(token: string, secret: string): {string: any}, string
    end

    crypto: crypto
    jwt: jwt
end
