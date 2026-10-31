global record security
    record crypto
        -- HMAC-SHA-256 over the RAW secret octets (RFC 7518 HS256),
        -- composed per RFC 2104 on lunet.sodium.sha256: a key longer
        -- than the 64-byte block is hashed first, every other key is
        -- used as-is and zero-padded to the block. Returns the raw
        -- 32-byte tag, or nil plus a message on operational failure
        -- (libsodium init).
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

        -- Extract-and-verify for an Authorization header: matches the
        -- scheme word (case-insensitive Bearer or Token, whitespace
        -- tolerant) then decodes. Returns the claims table and nil on
        -- success; on failure nil plus a kind word: "missing" (absent
        -- or empty header), "scheme" (scheme word not in the accepted
        -- set, or no token followed it), or a decode kind (malformed /
        -- sig / exp).
        -- `schemes` is required: a string or a non-empty array of
        -- strings naming the accepted scheme words. There is no default
        -- set.
        -- Malformed arguments (non-string non-nil header, bad secret,
        -- missing or malformed schemes) raise.
        bearer: function(authorization: string, secret: string, schemes: string | {string}): {string: any} | nil, string
    end

    crypto: crypto
    jwt: jwt
end
