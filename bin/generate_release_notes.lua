-- generate_release_notes.lua <tag> — build per-tag release notes.
--
-- Rules (see issue: releases must not share one static template):
--   * docs/release-notes/<tag>.md exists  -> use it verbatim as Highlights
--     (curated override; required when the commit history is not
--     conventional-commit clean).
--   * minor release (vX.Y.0)              -> Highlights = features only,
--     computed from `git log <previous minor line>..<tag> --format=%s`
--     entries starting with "feat".
--   * patch release (vX.Y.Z, Z > 0)       -> reuse the Highlights of its
--     line's minor notes -- curated docs/release-notes/vX.Y.0.md if present,
--     else vX.Y.0 on GitHub, else the earliest published vX.Y.* release --
--     then list the fixes in this patch range.
--
-- The generated "## Highlights" is followed by the static sections from
-- .github/release-template.md (Binaries / Embeddable SDKs / Quick Start).
--
-- Runs under `xmake lua`. Requires git tags (fetch-depth: 0) and, for the
-- patch path, the GitHub CLI with GH_TOKEN set.

-- xmake does not forward ordinary script arguments when it executes a
-- standalone file (same constraint as bin/generate_embed_scripts.lua),
-- so the tag arrives via environment.
local TAG = os.getenv("LUNET_RELEASE_TAG") or os.getenv("GITHUB_REF_NAME")
if not TAG or TAG == "" then
    raise("usage: LUNET_RELEASE_TAG=<tag> xmake lua bin/generate_release_notes.lua")
end

-- Run a command, returning trimmed stdout, or nil when it fails. os.iorun
-- raises on a non-zero exit, and the xmake script sandbox does not expose
-- pcall, so the failure has to be caught with try/catch.
local function sh(cmd)
    local out = nil
    try {
        function()
            out = os.iorun(cmd)
        end,
        catch {
            function() out = nil end
        }
    }
    if not out then
        return nil
    end
    return (out:gsub("%s+$", ""))
end

local function sh_or_die(cmd)
    local out = sh(cmd)
    if not out then
        raise("command failed: " .. cmd)
    end
    return out
end

-- Parse vX.Y.Z (suffix like "-plus" tolerated but excluded from tag ranges).
local function parse_version(tag)
    local x, y, z = tag:match("^v?(%d+)%.(%d+)%.(%d+)")
    if not x then
        return nil
    end
    return tonumber(x), tonumber(y), tonumber(z)
end

local X, Y, Z = parse_version(TAG)
if not X then
    raise("tag does not look like vX.Y.Z: " .. TAG)
end

-- Collect release-line tags (vX.Y.Z without suffix), sorted ascending.
local function sorted_tags()
    local tags = {}
    for tag in sh_or_die("git tag -l"):gmatch("[^\r\n]+") do
        if tag:match("^v%d+%.%d+%.%d+$") then
            local x, y, z = parse_version(tag)
            tags[#tags + 1] = { name = tag, x = x, y = y, z = z }
        end
    end
    table.sort(tags, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        if a.y ~= b.y then return a.y < b.y end
        return a.z < b.z
    end)
    return tags
end

-- The range end for git log: the tag itself, or HEAD when rehearsing
-- locally for a tag that does not exist yet.
local function range_end()
    if sh("git rev-parse --verify --quiet " .. TAG) then
        return TAG
    end
    io.stderr:write("[release-notes] tag " .. TAG .. " not found locally; using HEAD\n")
    return "HEAD"
end

-- Latest tag on a DIFFERENT (major, minor) line, i.e. where the previous
-- line ended. Returns nil for the first line ever released.
local function previous_line_tag(tags)
    local prev = nil
    for _, t in ipairs(tags) do
        if t.x == X and t.y == Y then
            break
        end
        prev = t
    end
    return prev and prev.name or nil
end

local function log_subjects(range)
    local out = sh_or_die("git log --no-merges --format=%s " .. range)
    local subjects = {}
    for line in out:gmatch("[^\r\n]+") do
        subjects[#subjects + 1] = line
    end
    return subjects
end

local function bullets_from_subjects(subjects, prefix)
    local bullets = {}
    for _, s in ipairs(subjects) do
        local body = s:match("^" .. prefix .. "[%(:!].-%)?:%s*(.+)$") or s:match("^" .. prefix .. ":%s*(.+)$")
        if body then
            bullets[#bullets + 1] = "- " .. body
        end
    end
    return bullets
end

-- Extract the "## Highlights ..." section (up to the next "## ") from a
-- release body.
local function extract_highlights(body)
    local section = body:match("##%s*Highlights%s*(.-)\n##%s")
    if not section then
        section = body:match("##%s*Highlights%s*(.-)$")
    end
    if not section then
        return nil
    end
    return (section:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Fetch the line notes for a patch release. A curated in-repo
-- docs/release-notes/vX.Y.0.md wins: it makes the whole line reproducible
-- from the checkout and does not depend on what happens to be published
-- (older lines predate this script and may still carry a stale shared
-- template, or may never have had a vX.Y.0 release at all). Otherwise fall
-- back to vX.Y.0 on GitHub, then the earliest published vX.Y.* release.
local function fetch_line_highlights()
    local minor_tag = string.format("v%d.%d.0", X, Y)

    local curated = path.join("docs", "release-notes", minor_tag .. ".md")
    if os.isfile(curated) then
        local content = io.readfile(curated)
        return (content:gsub("^%s+", ""):gsub("%s+$", "")), curated
    end

    -- No shell redirect here: os.iorun does not spawn a shell, so "2>/dev/null"
    -- would be passed to gh as a literal argument. sh() already returns nil on
    -- a non-zero exit.
    local body = sh("gh release view " .. minor_tag .. " --json body --jq .body")
    if body then
        local highlights = extract_highlights(body)
        if highlights then
            return highlights, minor_tag
        end
    end
    for patch = 1, Z do
        local tag = string.format("v%d.%d.%d", X, Y, patch)
        body = sh("gh release view " .. tag .. " --json body --jq .body")
        if body then
            local highlights = extract_highlights(body)
            if highlights then
                return highlights, tag
            end
        end
    end
    return nil, nil
end

local function compute_highlights()
    -- Curated override wins.
    local override = path.join("docs", "release-notes", TAG .. ".md")
    if os.isfile(override) then
        io.stderr:write("[release-notes] using curated " .. override .. "\n")
        local content = io.readfile(override)
        return (content:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    if Z == 0 then
        -- Minor: new features only, from the previous line's tip to this tag.
        local prev = previous_line_tag(sorted_tags())
        local range = prev and (prev .. ".." .. range_end()) or range_end()
        local bullets = bullets_from_subjects(log_subjects(range), "feat")
        if #bullets == 0 then
            bullets = { "- Maintenance release " .. TAG .. " (no feat:-prefixed commits in range " .. range .. ")" }
        end
        io.stderr:write("[release-notes] computed minor highlights from " .. range .. "\n")
        return table.concat(bullets, "\n")
    end

    -- Patch: reuse the line's highlights, then list this patch's fixes.
    local line_highlights, source_tag = fetch_line_highlights()
    -- The preceding patch tag is normally present in CI (fetch-depth: 0), but
    -- may be missing when rehearsing a not-yet-tagged release locally. Skip
    -- the fixes list rather than failing the whole run.
    local prev = string.format("v%d.%d.%d", X, Y, Z - 1)
    local fixes = {}
    if sh("git rev-parse --verify --quiet " .. prev) then
        fixes = bullets_from_subjects(log_subjects(prev .. ".." .. range_end()), "fix")
    else
        io.stderr:write("[release-notes] " .. prev .. " not found locally; omitting the fixes list\n")
    end
    local header = string.format("_Bugfix release on the %d.%d line; highlights carried over from %s._",
        X, Y, source_tag or "the line")
    local parts = { header, "" }
    if line_highlights then
        parts[#parts + 1] = line_highlights
        parts[#parts + 1] = ""
    else
        parts[#parts + 1] = "- (could not fetch the line highlights; see the changelog)"
        parts[#parts + 1] = ""
    end
    if #fixes > 0 then
        parts[#parts + 1] = "### Fixes in " .. TAG
        parts[#parts + 1] = ""
        parts[#parts + 1] = table.concat(fixes, "\n")
    end
    io.stderr:write("[release-notes] reused line highlights from " .. tostring(source_tag) .. "\n")
    return table.concat(parts, "\n")
end

local highlights = compute_highlights()
local static_body = io.readfile(path.join(".github", "release-template.md"))

print("## Highlights")
print("")
print(highlights)
print("")
print(static_body)
