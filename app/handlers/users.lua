local db = require("app.lib.db")
local http = require("app.lib.http")
local crypto = require("app.lib.crypto")
local auth = require("app.lib.auth")

local users = {}

local function user_response(user)
    return {
        user = {
            email = user.email,
            token = auth.generate_token(user.id),
            username = user.username,
            bio = user.bio or "",
            image = user.image or nil,
        }
    }
end

local function validate_email(email)
    if not email or email == "" then
        return false, "can't be blank"
    end
    if not email:match("^[%w._%+-]+@[%w.-]+%.[%w]+$") then
        return false, "is invalid"
    end
    return true
end

local function validate_username(username)
    if not username or username == "" then
        return false, "can't be blank"
    end
    if #username < 1 or #username > 50 then
        return false, "is too long (maximum is 50 characters)"
    end
    if not username:match("^[%w_]+$") then
        return false, "is invalid"
    end
    return true
end

local function validate_password(password)
    if not password or password == "" then
        return false, "can't be blank"
    end
    if #password < 8 then
        return false, "is too short (minimum is 8 characters)"
    end
    return true
end

function users.register(request)
    local data = request.json
    if not data or not data.user then
        return http.error_response(422, {body = {"Invalid request body"}})
    end

    local user_data = data.user
    local errors = {}

    local email_valid, email_err = validate_email(user_data.email)
    if not email_valid then
        errors.email = {email_err}
    end

    local username_valid, username_err = validate_username(user_data.username)
    if not username_valid then
        errors.username = {username_err}
    end

    local password_valid, password_err = validate_password(user_data.password)
    if not password_valid then
        errors.password = {password_err}
    end

    if next(errors) then
        return http.error_response(422, errors)
    end

    local existing = db.query_one("SELECT id FROM users WHERE email = ? OR username = ?",
        user_data.email, user_data.username)
    if existing then
        local conflict = db.query_one("SELECT id FROM users WHERE email = ?", user_data.email)
        if conflict then
            return http.error_response(422, {email = {"has already been taken"}})
        else
            return http.error_response(422, {username = {"has already been taken"}})
        end
    end

    local password_hash = crypto.hash_password(user_data.password)
    if not password_hash then
        return http.error_response(500, {body = {"Password hashing failed"}})
    end

    local result, insert_err = db.insert("users", {
        username = user_data.username,
        email = user_data.email,
        password_hash = password_hash,
    })

    if not result then
        return http.error_response(500, {body = {"User creation failed: " .. (insert_err or "")}})
    end

    local user = db.query_one("SELECT * FROM users WHERE id = ?", result.last_insert_id)
    if not user then
        return http.error_response(500, {body = {"Failed to retrieve created user"}})
    end

    return http.json_response(201, user_response(user))
end

function users.login(request)
    local data = request.json
    if not data or not data.user then
        return http.error_response(422, {body = {"Invalid request body"}})
    end

    local user_data = data.user
    if not user_data.email or user_data.email == "" then
        return http.error_response(422, {email = {"can't be blank"}})
    end
    if not user_data.password or user_data.password == "" then
        return http.error_response(422, {password = {"can't be blank"}})
    end

    local user = db.query_one("SELECT * FROM users WHERE email = ?", user_data.email)
    if not user then
        return http.error_response(422, {["email or password"] = {"is invalid"}})
    end

    if not crypto.verify_password(user_data.password, user.password_hash) then
        return http.error_response(422, {["email or password"] = {"is invalid"}})
    end

    return http.json_response(200, user_response(user))
end

function users.current(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local user = db.query_one("SELECT * FROM users WHERE id = ?", user_id)
    if not user then
        return http.error_response(404, {body = {"User not found"}})
    end

    return http.json_response(200, user_response(user))
end

function users.update(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local data = request.json
    if not data or not data.user then
        return http.error_response(422, {body = {"Invalid request body"}})
    end

    local user_data = data.user
    local updates = {}
    local errors = {}

    if user_data.email then
        local email_valid, email_err = validate_email(user_data.email)
        if not email_valid then
            errors.email = {email_err}
        else
            local existing = db.query_one("SELECT id FROM users WHERE email = ? AND id != ?",
                user_data.email, user_id)
            if existing then
                errors.email = {"has already been taken"}
            else
                updates.email = user_data.email
            end
        end
    end

    if user_data.username then
        local username_valid, username_err = validate_username(user_data.username)
        if not username_valid then
            errors.username = {username_err}
        else
            local existing = db.query_one("SELECT id FROM users WHERE username = ? AND id != ?",
                user_data.username, user_id)
            if existing then
                errors.username = {"has already been taken"}
            else
                updates.username = user_data.username
            end
        end
    end

    if user_data.password then
        local password_valid, password_err = validate_password(user_data.password)
        if not password_valid then
            errors.password = {password_err}
        else
            local password_hash = crypto.hash_password(user_data.password)
            if not password_hash then
                errors.password = {"hashing failed"}
            else
                updates.password_hash = password_hash
            end
        end
    end

    if user_data.bio ~= nil then
        updates.bio = user_data.bio
    end

    if user_data.image ~= nil then
        updates.image = user_data.image
    end

    if next(errors) then
        return http.error_response(422, errors)
    end

    if next(updates) then
        local result = db.update("users", updates, "id = ?", user_id)
        if not result then
            return http.error_response(500, {body = {"Update failed"}})
        end
    end

    local user = db.query_one("SELECT * FROM users WHERE id = ?", user_id)
    if not user then
        return http.error_response(404, {body = {"User not found"}})
    end

    return http.json_response(200, user_response(user))
end

return users
