local db = require("app.lib.db")
local http = require("app.lib.http")
local auth = require("app.lib.auth")

local comments = {}

local function format_timestamp(ts)
    if not ts then return nil end
    if type(ts) == "string" then
        return ts:gsub(" ", "T") .. ".000Z"
    end
    return os.date("!%Y-%m-%dT%H:%M:%S.000Z", ts)
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

local function comment_response(comment, author, user_id)
    return {
        id = comment.id,
        createdAt = format_timestamp(comment.created_at),
        updatedAt = format_timestamp(comment.updated_at),
        body = comment.body,
        author = {
            username = author.username,
            bio = author.bio or "",
            image = author.image or nil,
            following = is_following(user_id, author.id),
        }
    }
end

local function get_article_by_slug(slug)
    return db.query_one("SELECT * FROM articles WHERE slug = ?", slug)
end

function comments.list(request)
    auth.middleware(request)
    local user_id = request.user_id
    local slug = request.params.slug

    if not slug then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local article = get_article_by_slug(slug)
    if not article then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local rows = db.query(
        "SELECT c.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM comments c INNER JOIN users u ON u.id = c.author_id " ..
        "WHERE c.article_id = ? ORDER BY c.created_at DESC",
        article.id
    )

    local result = {}
    if rows then
        for _, row in ipairs(rows) do
            local author = {
                id = row.author_id,
                username = row.username,
                bio = row.bio,
                image = row.image,
            }
            result[#result + 1] = comment_response(row, author, user_id)
        end
    end

    return http.json_response(200, {comments = result})
end

function comments.create(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local slug = request.params.slug
    if not slug then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local article = get_article_by_slug(slug)
    if not article then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local data = request.json
    if not data or not data.comment then
        return http.error_response(422, {body = {"Invalid request body"}})
    end

    local comment_data = data.comment
    if not comment_data.body or comment_data.body == "" then
        return http.error_response(422, {body = {"can't be blank"}})
    end

    local result = db.insert("comments", {
        body = comment_data.body,
        article_id = article.id,
        author_id = user_id,
    })

    if not result then
        return http.error_response(500, {body = {"Failed to create comment"}})
    end

    local row = db.query_one(
        "SELECT c.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM comments c INNER JOIN users u ON u.id = c.author_id " ..
        "WHERE c.id = ?",
        result.last_insert_id
    )

    local author = {
        id = row.author_id,
        username = row.username,
        bio = row.bio,
        image = row.image,
    }

    return http.json_response(200, {comment = comment_response(row, author, user_id)})
end

function comments.delete(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local slug = request.params.slug
    local comment_id = tonumber(request.params.id)

    if not slug then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local article = get_article_by_slug(slug)
    if not article then
        return http.error_response(404, {body = {"Article not found"}})
    end

    if not comment_id then
        return http.error_response(404, {body = {"Comment not found"}})
    end

    local comment = db.query_one(
        "SELECT * FROM comments WHERE id = ? AND article_id = ?",
        comment_id, article.id
    )

    if not comment then
        return http.error_response(404, {body = {"Comment not found"}})
    end

    if comment.author_id ~= user_id then
        return http.error_response(403, {body = {"You are not the author"}})
    end

    db.delete("comments", "id = ?", comment_id)

    return http.response(204, {["Content-Length"] = "0"}, "")
end

return comments
