local crypto = require("app.lib.crypto")
local json = require("app.lib.json")

local auth = {}

local config = {
    secret = "change-me-in-production",
    expiry = 86400 * 7,
}

function auth.set_config(cfg)
    if not cfg or not cfg.jwt_secret or cfg.jwt_secret == "change-me-in-production" then
        io.stderr:write("WARNING: Using default/weak JWT secret. Do not use in production.\n")
    end
    if cfg.jwt_secret then config.secret = cfg.jwt_secret end
    if cfg.jwt_expiry then config.expiry = cfg.jwt_expiry end
end

function auth.generate_token(user_id)
    local header = {alg = "HS256", typ = "JWT"}
    local payload = {
        user_id = user_id,
        exp = os.time() + config.expiry,
        iat = os.time(),
    }

    local header_b64 = crypto.base64_encode(json.encode(header), true)
    local payload_b64 = crypto.base64_encode(json.encode(payload), true)
    local message = header_b64 .. "." .. payload_b64
    local signature = crypto.hmac_sha256(message, config.secret)
    local signature_b64 = crypto.base64_encode(signature, true)

    return message .. "." .. signature_b64
end

function auth.decode_token(token)
    if not token or type(token) ~= "string" then
        return nil, "invalid token"
    end

    local parts = {}
    for part in token:gmatch("[^.]+") do
        parts[#parts + 1] = part
    end

    if #parts ~= 3 then
        return nil, "invalid token format"
    end

    local header_b64, payload_b64, signature_b64 = parts[1], parts[2], parts[3]
    local message = header_b64 .. "." .. payload_b64
    local expected_sig = crypto.hmac_sha256(message, config.secret)
    local expected_sig_b64 = crypto.base64_encode(expected_sig, true)

    if not crypto.constant_time_compare(signature_b64, expected_sig_b64) then
        return nil, "invalid signature"
    end

    local header_json = crypto.base64_decode(header_b64, true)
    if not header_json then
        return nil, "invalid header encoding"
    end
    local ok_h, header = pcall(json.decode, header_json)
    if not ok_h or header.alg ~= "HS256" or header.typ ~= "JWT" then
        return nil, "invalid header"
    end

    local payload_json = crypto.base64_decode(payload_b64, true)
    if not payload_json then
        return nil, "invalid payload encoding"
    end

    local ok, payload = pcall(json.decode, payload_json)
    if not ok then
        return nil, "invalid payload JSON"
    end

    if payload.exp and payload.exp < os.time() then
        return nil, "token expired"
    end

    return payload.user_id, nil
end

function auth.middleware(request)
    local auth_header = request.headers and request.headers["authorization"]
    if not auth_header then
        return nil
    end

    local token = auth_header:match("^Token%s+(.+)$")
    if not token then
        token = auth_header:match("^Bearer%s+(.+)$")
    end

    if not token then
        return nil
    end

    local user_id = auth.decode_token(token)
    if not user_id then
        return nil
    end

    request.user_id = user_id
    return user_id
end

function auth.require_auth(request)
    local user_id = auth.middleware(request)
    if not user_id then
        return nil, "authentication required"
    end
    return user_id
end

return auth
