local db = require("app.lib.db")
local http = require("app.lib.http")

local tags = {}

function tags.list(_request)
    local rows = db.query("SELECT DISTINCT name FROM tags ORDER BY name")

    local result = {}
    if rows then
        for _, row in ipairs(rows) do
            result[#result + 1] = row.name
        end
    end

    return http.json_response(200, {tags = result})
end

return tags
