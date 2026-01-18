local db = require("app.lib.db")
local http = require("app.lib.http")
local auth = require("app.lib.auth")
local crypto = require("app.lib.crypto")

local articles = {}

local function generate_slug(title)
    local slug = title:lower()
    slug = slug:gsub("[^%w%s-]", "")
    slug = slug:gsub("%s+", "-")
    slug = slug:gsub("%-+", "-")
    slug = slug:gsub("^%-+", "")
    slug = slug:gsub("%-+$", "")
    local suffix = ""
    local bytes = crypto.random_bytes(4)
    for i = 1, #bytes do
        suffix = suffix .. string.format("%02x", bytes:byte(i))
    end
    return slug .. "-" .. suffix
end

local function get_tags_for_article(article_id)
    local rows = db.query(
        "SELECT t.name FROM tags t " ..
        "INNER JOIN article_tags at ON at.tag_id = t.id " ..
        "WHERE at.article_id = ?",
        article_id
    )
    local tags = {}
    if rows then
        for _, row in ipairs(rows) do
            tags[#tags + 1] = row.name
        end
    end
    return tags
end

local function is_favorited(user_id, article_id)
    if not user_id then
        return false
    end
    local fav = db.query_one(
        "SELECT 1 FROM favorites WHERE user_id = ? AND article_id = ?",
        user_id, article_id
    )
    return fav ~= nil
end

local function favorites_count(article_id)
    local result = db.query_one(
        "SELECT COUNT(*) as count FROM favorites WHERE article_id = ?",
        article_id
    )
    return result and tonumber(result.count) or 0
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

local function format_timestamp(ts)
    if not ts then return nil end
    if type(ts) == "string" then
        return ts:gsub(" ", "T") .. ".000Z"
    end
    return os.date("!%Y-%m-%dT%H:%M:%S.000Z", ts)
end

local function article_response(article, author, user_id)
    return {
        slug = article.slug,
        title = article.title,
        description = article.description or "",
        body = article.body or "",
        tagList = get_tags_for_article(article.id),
        createdAt = format_timestamp(article.created_at),
        updatedAt = format_timestamp(article.updated_at),
        favorited = is_favorited(user_id, article.id),
        favoritesCount = favorites_count(article.id),
        author = {
            username = author.username,
            bio = author.bio or "",
            image = author.image or nil,
            following = is_following(user_id, author.id),
        }
    }
end

local function sync_tags(article_id, tag_list)
    db.delete("article_tags", "article_id = ?", article_id)
    if not tag_list or #tag_list == 0 then
        return
    end
    for _, tag_name in ipairs(tag_list) do
        local tag = db.query_one("SELECT id FROM tags WHERE name = ?", tag_name)
        if not tag then
            local result = db.insert("tags", {name = tag_name})
            if result then
                tag = {id = result.last_insert_id}
            end
        end
        if tag then
            db.insert("article_tags", {
                article_id = article_id,
                tag_id = tag.id,
            })
        end
    end
end

function articles.list(request)
    auth.middleware(request)
    local user_id = request.user_id
    local params = request.query_params

    local limit = tonumber(params.limit) or 20
    local offset = tonumber(params.offset) or 0
    limit = math.min(limit, 100)

    local where_clauses = {}
    local where_values = {}

    if params.tag and params.tag ~= "" then
        where_clauses[#where_clauses + 1] =
            "a.id IN (SELECT at.article_id FROM article_tags at " ..
            "INNER JOIN tags t ON t.id = at.tag_id WHERE t.name = ?)"
        where_values[#where_values + 1] = params.tag
    end

    if params.author and params.author ~= "" then
        where_clauses[#where_clauses + 1] = "u.username = ?"
        where_values[#where_values + 1] = params.author
    end

    if params.favorited and params.favorited ~= "" then
        where_clauses[#where_clauses + 1] =
            "a.id IN (SELECT f.article_id FROM favorites f " ..
            "INNER JOIN users fu ON fu.id = f.user_id WHERE fu.username = ?)"
        where_values[#where_values + 1] = params.favorited
    end

    local where_sql = ""
    if #where_clauses > 0 then
        where_sql = "WHERE " .. table.concat(where_clauses, " AND ")
    end

    local count_sql = "SELECT COUNT(*) as count FROM articles a " ..
        "INNER JOIN users u ON u.id = a.author_id " .. where_sql
    local count_result = db.query_one(count_sql, table.unpack(where_values))
    local total = count_result and tonumber(count_result.count) or 0

    local sql = "SELECT a.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM articles a INNER JOIN users u ON u.id = a.author_id " ..
        where_sql .. " ORDER BY a.created_at DESC LIMIT ? OFFSET ?"

    local query_values = {}
    for _, v in ipairs(where_values) do
        query_values[#query_values + 1] = v
    end
    query_values[#query_values + 1] = limit
    query_values[#query_values + 1] = offset

    local rows = db.query(sql, table.unpack(query_values))

    local result = {}
    if rows then
        for _, row in ipairs(rows) do
            local author = {
                id = row.author_id,
                username = row.username,
                bio = row.bio,
                image = row.image,
            }
            result[#result + 1] = article_response(row, author, user_id)
        end
    end

    return http.json_response(200, {articles = result, articlesCount = total})
end

function articles.feed(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local params = request.query_params
    local limit = tonumber(params.limit) or 20
    local offset = tonumber(params.offset) or 0
    limit = math.min(limit, 100)

    local count_sql = "SELECT COUNT(*) as count FROM articles a " ..
        "INNER JOIN follows f ON f.followed_id = a.author_id " ..
        "WHERE f.follower_id = ?"
    local count_result = db.query_one(count_sql, user_id)
    local total = count_result and tonumber(count_result.count) or 0

    local sql = "SELECT a.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM articles a " ..
        "INNER JOIN users u ON u.id = a.author_id " ..
        "INNER JOIN follows f ON f.followed_id = a.author_id " ..
        "WHERE f.follower_id = ? " ..
        "ORDER BY a.created_at DESC LIMIT ? OFFSET ?"

    local rows = db.query(sql, user_id, limit, offset)

    local result = {}
    if rows then
        for _, row in ipairs(rows) do
            local author = {
                id = row.author_id,
                username = row.username,
                bio = row.bio,
                image = row.image,
            }
            result[#result + 1] = article_response(row, author, user_id)
        end
    end

    return http.json_response(200, {articles = result, articlesCount = total})
end

function articles.get(request)
    auth.middleware(request)
    local user_id = request.user_id
    local slug = request.params.slug

    if not slug then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local row = db.query_one(
        "SELECT a.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM articles a INNER JOIN users u ON u.id = a.author_id " ..
        "WHERE a.slug = ?",
        slug
    )

    if not row then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local author = {
        id = row.author_id,
        username = row.username,
        bio = row.bio,
        image = row.image,
    }

    return http.json_response(200, {article = article_response(row, author, user_id)})
end

function articles.create(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local data = request.json
    if not data or not data.article then
        return http.error_response(422, {body = {"Invalid request body"}})
    end

    local article_data = data.article
    local errors = {}

    if not article_data.title or article_data.title == "" then
        errors.title = {"can't be blank"}
    end
    if not article_data.description or article_data.description == "" then
        errors.description = {"can't be blank"}
    end
    if not article_data.body or article_data.body == "" then
        errors.body = {"can't be blank"}
    end

    if next(errors) then
        return http.error_response(422, errors)
    end

    local slug = generate_slug(article_data.title)

    local result = db.insert("articles", {
        slug = slug,
        title = article_data.title,
        description = article_data.description,
        body = article_data.body,
        author_id = user_id,
    })

    if not result then
        return http.error_response(500, {body = {"Failed to create article"}})
    end

    local article_id = result.last_insert_id

    if article_data.tagList and type(article_data.tagList) == "table" then
        sync_tags(article_id, article_data.tagList)
    end

    local row = db.query_one(
        "SELECT a.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM articles a INNER JOIN users u ON u.id = a.author_id " ..
        "WHERE a.id = ?",
        article_id
    )

    local author = {
        id = row.author_id,
        username = row.username,
        bio = row.bio,
        image = row.image,
    }

    return http.json_response(201, {article = article_response(row, author, user_id)})
end

function articles.update(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local slug = request.params.slug
    if not slug then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local article = db.query_one("SELECT * FROM articles WHERE slug = ?", slug)
    if not article then
        return http.error_response(404, {body = {"Article not found"}})
    end

    if article.author_id ~= user_id then
        return http.error_response(403, {body = {"You are not the author"}})
    end

    local data = request.json
    if not data or not data.article then
        return http.error_response(422, {body = {"Invalid request body"}})
    end

    local article_data = data.article
    local updates = {}

    if article_data.title and article_data.title ~= "" then
        updates.title = article_data.title
        updates.slug = generate_slug(article_data.title)
    end
    if article_data.description then
        updates.description = article_data.description
    end
    if article_data.body then
        updates.body = article_data.body
    end

    if next(updates) then
        db.update("articles", updates, "id = ?", article.id)
    end

    if article_data.tagList and type(article_data.tagList) == "table" then
        sync_tags(article.id, article_data.tagList)
    end

    local row = db.query_one(
        "SELECT a.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM articles a INNER JOIN users u ON u.id = a.author_id " ..
        "WHERE a.id = ?",
        article.id
    )

    local author = {
        id = row.author_id,
        username = row.username,
        bio = row.bio,
        image = row.image,
    }

    return http.json_response(200, {article = article_response(row, author, user_id)})
end

function articles.delete(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local slug = request.params.slug
    if not slug then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local article = db.query_one("SELECT * FROM articles WHERE slug = ?", slug)
    if not article then
        return http.error_response(404, {body = {"Article not found"}})
    end

    if article.author_id ~= user_id then
        return http.error_response(403, {body = {"You are not the author"}})
    end

    db.delete("articles", "id = ?", article.id)

    return http.response(204, {["Content-Length"] = "0"}, "")
end

function articles.favorite(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local slug = request.params.slug
    if not slug then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local row = db.query_one(
        "SELECT a.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM articles a INNER JOIN users u ON u.id = a.author_id " ..
        "WHERE a.slug = ?",
        slug
    )

    if not row then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local existing = db.query_one(
        "SELECT 1 FROM favorites WHERE user_id = ? AND article_id = ?",
        user_id, row.id
    )

    if not existing then
        db.insert("favorites", {
            user_id = user_id,
            article_id = row.id,
        })
    end

    local author = {
        id = row.author_id,
        username = row.username,
        bio = row.bio,
        image = row.image,
    }

    return http.json_response(200, {article = article_response(row, author, user_id)})
end

function articles.unfavorite(request)
    local user_id, err = auth.require_auth(request)
    if not user_id then
        return http.error_response(401, {body = {err}})
    end

    local slug = request.params.slug
    if not slug then
        return http.error_response(404, {body = {"Article not found"}})
    end

    local row = db.query_one(
        "SELECT a.*, u.id as author_id, u.username, u.bio, u.image " ..
        "FROM articles a INNER JOIN users u ON u.id = a.author_id " ..
        "WHERE a.slug = ?",
        slug
    )

    if not row then
        return http.error_response(404, {body = {"Article not found"}})
    end

    db.delete("favorites", "user_id = ? AND article_id = ?", user_id, row.id)

    local author = {
        id = row.author_id,
        username = row.username,
        bio = row.bio,
        image = row.image,
    }

    return http.json_response(200, {article = article_response(row, author, user_id)})
end

return articles
