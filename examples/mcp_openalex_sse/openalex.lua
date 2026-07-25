-- OpenAlex API client on lunet.httpc (libcurl). Free API, key required:
-- create one at https://openalex.org/settings/api and put it in .env.
-- Costs with a key: singleton GETs are free, a search is about $0.001,
-- and the free daily budget is $1 — this client is deliberately frugal.

local httpc = require("lunet.httpc")

local json = require("json")

local M = {}

local BASE = "https://api.openalex.org"

local function urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function get_json(client, path)
    local sep = path:find("?", 1, true) and "&" or "?"
    local url = BASE .. path .. sep .. "api_key=" .. urlencode(client.api_key)
    local resp, err = httpc.request({ url = url, timeout_ms = 10000 })
    if not resp then
        return nil, "http error: " .. tostring(err)
    end
    if resp.status == 429 then
        return nil, "OpenAlex rate limit hit (429); try again tomorrow or add credits"
    end
    if resp.status ~= 200 then
        local snippet = (resp.body or ""):sub(1, 200)
        return nil, string.format("OpenAlex returned HTTP %d: %s", resp.status, snippet)
    end
    local data, derr = json.decode(resp.body)
    if not data then
        return nil, "could not decode OpenAlex response: " .. tostring(derr)
    end
    return data
end

local function author_names(work, max_names)
    local names = {}
    local authorships = work.authorships or {}
    for i, a in ipairs(authorships) do
        if i > (max_names or 3) then break end
        if a.author and a.author.display_name then
            names[#names + 1] = a.author.display_name
        end
    end
    if #authorships > (max_names or 3) then
        names[#names + 1] = "et al."
    end
    return table.concat(names, ", ")
end

local function work_line(work)
    local title = work.display_name or "(untitled)"
    local year = work.publication_year or "?"
    local authors = author_names(work)
    if authors ~= "" then authors = " — " .. authors end
    local cited = work.cited_by_count or 0
    local id = work.id or ""
    return string.format("%s (%s)%s — cited %d times — %s", title, year, authors, cited, id)
end

local function reconstruct_abstract(inverted_index)
    if type(inverted_index) ~= "table" then return nil end
    local words = {}
    local max_pos = -1
    for word, positions in pairs(inverted_index) do
        for _, p in ipairs(positions) do
            words[p] = word
            if p > max_pos then max_pos = p end
        end
    end
    if max_pos < 0 then return nil end
    local out = {}
    for i = 0, max_pos do
        out[#out + 1] = words[i] or ""
    end
    return table.concat(out, " ")
end

function M.new(api_key)
    if not api_key or api_key == "" then
        return nil, "OPEN_ALEX_API_KEY is not set (create one free at https://openalex.org/settings/api)"
    end
    local client = { api_key = api_key }

    -- Search scholarly works. Returns formatted text lines, or nil + error.
    function client.search_works(query, limit)
        if not query or query == "" then
            return nil, "query must not be empty"
        end
        limit = math.floor(tonumber(limit) or 5)
        if limit < 1 then limit = 1 end
        if limit > 25 then limit = 25 end
        local data, err = get_json(client, string.format(
            "/works?search=%s&per-page=%d", urlencode(query), limit))
        if not data then return nil, err end
        local results = data.results or {}
        if #results == 0 then
            return "No works found for: " .. query
        end
        local lines = { string.format("OpenAlex works for '%s' (%d of %d):",
            query, #results, (data.meta and data.meta.count) or 0) }
        for i, work in ipairs(results) do
            lines[#lines + 1] = string.format("%d. %s", i, work_line(work))
        end
        return table.concat(lines, "\n")
    end

    -- Fetch one work by OpenAlex ID (W...), DOI, or full URL. Free endpoint.
    function client.get_work(id)
        if not id or id == "" then
            return nil, "id must not be empty"
        end
        local key = id
        if not key:match("^https?://") then
            if key:match("^10%.%d") or key:lower():match("^doi:") then
                key = key:gsub("^[Dd][Oo][Ii]:", "")
                key = "https://doi.org/" .. key
            elseif not key:match("^W%d+$") then
                return nil, "id should be an OpenAlex ID (W...), a DOI, or a URL"
            end
        end
        local data, err = get_json(client, "/works/" .. urlencode(key))
        if not data then return nil, err end
        local names = author_names(data, 10)
        local lines = {
            (data.display_name or "(untitled)") ..
                " (" .. tostring(data.publication_year or "?") .. ")",
            "Authors: " .. (names ~= "" and names or "unknown"),
        }
        local venue = data.primary_location and data.primary_location.source
        if venue and venue.display_name then
            lines[#lines + 1] = "Venue: " .. venue.display_name
        end
        lines[#lines + 1] = "Cited by: " .. tostring(data.cited_by_count or 0)
        if data.doi then lines[#lines + 1] = "DOI: " .. data.doi end
        local oa = data.open_access
        if oa and oa.oa_url then lines[#lines + 1] = "Open access: " .. oa.oa_url end
        if data.id then lines[#lines + 1] = "OpenAlex: " .. data.id end
        local abstract = reconstruct_abstract(data.abstract_inverted_index)
        if abstract then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Abstract: " .. abstract
        end
        return table.concat(lines, "\n")
    end

    -- Search authors by name. Returns formatted text lines, or nil + error.
    function client.search_authors(query, limit)
        if not query or query == "" then
            return nil, "query must not be empty"
        end
        limit = math.floor(tonumber(limit) or 5)
        if limit < 1 then limit = 1 end
        if limit > 25 then limit = 25 end
        local data, err = get_json(client, string.format(
            "/authors?search=%s&per-page=%d", urlencode(query), limit))
        if not data then return nil, err end
        local results = data.results or {}
        if #results == 0 then
            return "No authors found for: " .. query
        end
        local lines = { string.format("OpenAlex authors for '%s':", query) }
        for i, author in ipairs(results) do
            local inst = author.last_known_institutions
                and author.last_known_institutions[1]
                and author.last_known_institutions[1].display_name
                or "unknown affiliation"
            lines[#lines + 1] = string.format(
                "%d. %s — %s — works: %d, cited: %d — %s",
                i, author.display_name or "(unnamed)", inst,
                author.works_count or 0, author.cited_by_count or 0,
                author.id or "")
        end
        return table.concat(lines, "\n")
    end

    return client
end

return M
