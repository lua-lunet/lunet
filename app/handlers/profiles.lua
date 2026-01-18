local db = require("app.lib.db")
local http = require("app.lib.http")
local auth = require("app.lib.auth")

local profiles = {}

local function profile_response(user, following)
    return {
        profile = {
            username = user.username,
            bio = user.bio or "",
            image = user.image or nil,
            following = following or false,
        }
    }
end

local function is_following(follower_id, followed_id)
    if not follower_id then
        return false
    end
    local follow = db.query_one(
        "SELECT 1 FROM follows WHERE follower_id = ? AND followed_id = ?",
        follower_id, followed_id
    )
    return follow ~= nil
end

function profiles.get(request)
    local username = request.params.username
    if not username then
        return http.error_response(404, {body = {"Profile not found"}})
    end

    local user = db.query_one("SELECT * FROM users WHERE username = ?", username)
    if not user then
        return http.error_response(404, {body = {"Profile not found"}})
    end

    auth.middleware(request)
    local following = is_following(request.user_id, user.id)

    return http.json_response(200, profile_response(user, following))
end

function profiles.follow(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local username = request.params.username
    if not username then
        return http.error_response(404, {body = {"Profile not found"}})
    end

    local user = db.query_one("SELECT * FROM users WHERE username = ?", username)
    if not user then
        return http.error_response(404, {body = {"Profile not found"}})
    end

    if user.id == user_id then
        return http.error_response(422, {body = {"You cannot follow yourself"}})
    end

    local existing = db.query_one(
        "SELECT 1 FROM follows WHERE follower_id = ? AND followed_id = ?",
        user_id, user.id
    )

    if not existing then
        db.insert("follows", {
            follower_id = user_id,
            followed_id = user.id,
        })
    end

    return http.json_response(200, profile_response(user, true))
end

function profiles.unfollow(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local username = request.params.username
    if not username then
        return http.error_response(404, {body = {"Profile not found"}})
    end

    local user = db.query_one("SELECT * FROM users WHERE username = ?", username)
    if not user then
        return http.error_response(404, {body = {"Profile not found"}})
    end

    db.delete("follows", "follower_id = ? AND followed_id = ?", user_id, user.id)

    return http.json_response(200, profile_response(user, false))
end

return profiles
