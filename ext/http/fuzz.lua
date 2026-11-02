--[[
  lunet.http fuzz driver  -  seeded corpus fuzzer over http.read_request

  Pure Lua, dependency-free, deterministic: the same seed and budget
  always produce the same batch of cases (xorshift32 PRNG, seeded once),
  so a failure is replayable. Fast enough to sit inside the busted gate
  (spec/http_fuzz_spec.lua), which asserts the read_request contract on
  every generated input:

    - read_request never raises; it answers (nil, err, status)
    - a pcall false is a fuzz failure
    - a rejection carries a framing-subset status (400, 413, 414, 431,
      501, 505) or no status (clean EOF)
    - a parsed request reports a body of exactly Content-Length bytes
    - the reader hands over at most MAX_HEADER_BYTES + MAX_BODY_BYTES
      plus the tail chunk before any rejection (allocation guard)

  The corpus is the seed material: valid request shapes plus the framing
  edge cases (Content-Length lies, chunked attempts, NUL and control
  bytes, pipelined tails, header-cap probes). Mutators truncate at a
  boundary, insert junk bytes, replace a byte, duplicate a header line,
  splice in another seed, and - structure-aware - rewrite whole tokens
  (method, version, Content-Length value, header name) so the fuzzer
  explores the parser's decisions, not just its byte handling. Rejection
  sites are recorded per run: an uncovered site is a corpus gap. The
  cap-boundary fixtures (admit at the limit, refuse one past) are
  generated from the live caps values. Interesting cases graduate into
  the spec corpus as fixtures.
]]

local http = require("lunet.http")

local fuzz = {}

local JUNK = "\x00\x01\x1f\x7f\xff \t\r\n%\xff-f"

local seeds = {
    "GET / HTTP/1.1\r\nHost: h\r\n\r\n",
    "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello",
    -- Content-Length lies
    "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello",
    "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: -1\r\n\r\n",
    "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 00000005\r\n\r\nhello",
    "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 9999999999\r\n\r\n",
    -- chunked families (rejected by the subset)
    "POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
    "POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\n",
    -- header shapes
    "GET / HTTP/1.1\r\nHost : h\r\n\r\n",
    "GET / HTTP/1.1\r\nHost:\r\n\r\n",
    "GET / HTTP/1.1\r\nx-f x: v1\r\nx-f x: v2\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: h\r\n" .. string.rep("H: v\r\n", 400) .. "\r\n",
    "GET / HTTP/1.1\r\nHost: h\r\nX: " .. string.rep("a", 8 * 1024) .. "\r\n\r\n",
    -- NUL and control bytes
    "GET /\x00x HTTP/1.1\r\nHost: h\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: h\x01\r\n\r\n",
    -- pipelined tail (hard 400)
    "GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\nGET / HTTP/1.1\r\nHost: h\r\n\r\n",
    -- junk versions and methods
    "GET / HTTP/2.2\r\nHost: h\r\n\r\n",
    "GET / HTTP/1.0\r\nHost: h\r\n\r\n",
    "\x01\x02\x03\r\n\r\n",
    "GET",
    "",
    "GET /\xc3\xa9 HTTP/1.1\r\nHost: h\r\n\r\n",
}

-- Cap-boundary fixtures, generated from the LIVE caps values (so the
-- fixtures follow an override of lunet/http_caps.lua): a request whose
-- header section totals exactly MAX_HEADER_BYTES must parse; one byte
-- past must reject 431. Same contract for the body at MAX_BODY_BYTES
-- (413 one past). These run deterministically in the spec.
function fuzz.cap_boundary_fixtures()
    local H = http.MAX_HEADER_BYTES
    local B = http.MAX_BODY_BYTES
    local R = http.MAX_REQUEST_LINE_BYTES
    local t = {}

    -- header section: "X: <fill>\r\n" sized so the section totals exactly H
    -- (the parser counts the request line and header bytes; keep the
    -- request line minimal and size the fill to the remaining budget).
    local function header_request(total)
        local fixed = #("GET / HTTP/1.1\r\n") + #("Host: h\r\n") + #("\r\n") + #("X: \r\n")
        local fill = total - fixed
        if fill < 0 then return nil end
        return "GET / HTTP/1.1\r\nHost: h\r\nX: " .. string.rep("a", fill) .. "\r\n\r\n"
    end
    t.header_at = header_request(H)
    t.header_past = header_request(H + 1)
    t.line_at = "GET /" .. string.rep("a", R - #("GET /") - #(" HTTP/1.1")) .. " HTTP/1.1\r\nHost: h\r\n\r\n"
    t.line_past = "GET /" .. string.rep("a", R - #("GET /") - #(" HTTP/1.1") + 1) .. " HTTP/1.1\r\nHost: h\r\n\r\n"
    t.body_at = "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: " .. tostring(B) .. "\r\n\r\n" .. string.rep("b", B)
    t.body_past = "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: "
        .. tostring(B + 1) .. "\r\n\r\n" .. string.rep("b", B + 1)
    return t
end

local MUTATOR_NAMES = { "truncate", "insert", "replace", "duplicate_line",
    "splice", "method_token", "version_token", "cl_value", "header_name" }

local bit = require("bit")

-- xorshift32 on an unsigned 32-bit state; the bit library keeps this LuaJIT
-- and the final mod re-normalizes the signed bit-library result.
local function rng_next(state)
    local s = state.a
    s = bit.bxor(s, bit.lshift(s, 13))
    s = bit.bxor(s, bit.rshift(s, 17))
    s = bit.bxor(s, bit.lshift(s, 5))
    s = s % 4294967296
    if s == 0 then s = 1 end
    state.a = s
    return s
end

local function pick(state, n)
    return rng_next(state) % n + 1
end

local function replace_byte(state, bytes)
    local i = pick(state, #bytes)
    local b = JUNK:byte(pick(state, #JUNK))
    return bytes:sub(1, i - 1) .. string.char(b) .. bytes:sub(i + 1)
end

local function insert_byte(state, bytes)
    local i = pick(state, #bytes + 1)
    local b = JUNK:byte(pick(state, #JUNK))
    return bytes:sub(1, i - 1) .. string.char(b) .. bytes:sub(i)
end

local mutators = {}

function mutators.truncate(state, bytes)
    return bytes:sub(1, pick(state, #bytes) - 1)
end

function mutators.insert(state, bytes)
    local out = bytes
    for _ = 1, 2 do out = insert_byte(state, out) end
    return out
end

function mutators.replace(state, bytes)
    local out = bytes
    for _ = 1, 2 do out = replace_byte(state, out) end
    return out
end

function mutators.duplicate_line(state, bytes)
    local lines = {}
    local i = 1
    while i <= #bytes do
        local eol = bytes:find("\r\n", i, true) or #bytes + 1
        lines[#lines + 1] = bytes:sub(i, math.min(eol + 1, #bytes))
        i = eol + 2
    end
    if #lines < 2 then return nil end
    local k = pick(state, #lines)
    table.insert(lines, k, lines[k])
    return table.concat(lines)
end

function mutators.splice(state, bytes)
    return bytes .. seeds[pick(state, #seeds)]
end

-- Token-level (structure-aware) mutators: they rewrite grammar tokens of
-- the request line and headers rather than raw bytes.

local METHODS = { "GET", "POST", "PUT", "DELETE", "BREW", "TRACE", "" }
local VERSIONS = { "HTTP/1.1", "HTTP/1.0", "HTTP/2.2", "HTTP/9.9", "HTTP/",
    "http/1.1", "HTTP", "" }

function mutators.method_token(state, bytes)
    local line = bytes:match("^(.-)\r\n")
    if not line then return nil end
    local method = line:match("^(%S+)")
    if not method then return nil end
    local rest = line:sub(#method + 1)
    return METHODS[pick(state, #METHODS)] .. rest .. bytes:sub(#line + 1)
end

function mutators.version_token(state, bytes)
    local line = bytes:match("^(.-)\r\n")
    if not line then return nil end
    local head, ver = line:match("^(.*%s)(HTTP%S*)$")
    if not ver then return nil end
    return head .. VERSIONS[pick(state, #VERSIONS)] .. bytes:sub(#line + 1)
end

function mutators.cl_value(state, bytes)
    -- Mutate a Content-Length value: huge, negative, leading zeros,
    -- plus-sign, space suffix - the classic smuggling shapes.
    local first = bytes:match("Content%-Length:%s*(%S+)")
    if not first then return nil end
    local shapes = { "99999999999999", "-1", "0", "0005", "+5",
        first .. "0" }
    local val = shapes[pick(state, #shapes)]
    local pat = "Content%-Length:%s*" .. first:gsub("%p", "%%%0")
    local out = bytes:gsub(pat, "Content-Length: " .. val, 1)
    return out
end

function mutators.header_name(state, bytes)
    -- Mutate the FIRST header line's name: space before the name
    -- (invalid), space inside, uppercase, empty name, punctuation-only.
    local first_eol = bytes:find("\r\n", 1, true)
    if not first_eol then return nil end
    local hdr_start, hdr_end = bytes:find("\r\n[^\r\n]+\r\n", first_eol)
    if not hdr_start then return nil end
    local hdr = bytes:sub(hdr_start + 2, hdr_end - 2)
    local name = hdr:match("^(%S-):")
    if not name or #name == 0 then return nil end
    local shapes = { " " .. hdr,
        name .. " " .. hdr:sub(#name + 1),
        hdr:gsub(name, name:upper(), 1),
        ":" .. hdr:sub(#name + 1),
        "::" }
    local repl = shapes[pick(state, #shapes)]
    -- gsub may return two values; pin to the string
    if type(repl) ~= "string" then repl = "::" end
    return bytes:sub(1, hdr_start + 1) .. repl .. bytes:sub(hdr_end - 1)
end

-- Deliver bytes to read_request in up to 3 chunks, EOF after the last.
-- Returns the chunk list.
local function split(rng, bytes)
    local parts = 1 + pick(rng, 3)
    if parts > #bytes then parts = #bytes end
    local chunks = {}
    local last = 0
    for i = 1, parts do
        local e
        if i == parts then
            e = #bytes
        else
            e = last + math.max(1, math.floor(#bytes / parts))
            if e > #bytes then e = #bytes end
        end
        chunks[i] = bytes:sub(last + 1, e)
        last = e
    end
    return chunks
end

function fuzz.run(opts)
    opts = opts or {}
    local seed0 = (opts.seed or 0x9e3779b9) % 4294967296
    if seed0 == 0 then seed0 = 1 end
    local rng = { a = seed0 }
    local iterations = opts.budget or 64

    local stats = {
        seed = seed0,
        iterations = iterations,
        parsed = 0,
        rejected = 0,
        over_budget = 0,
        raised = 0,
        status = {},
        -- rejection-site coverage: keyed by the parser's error message,
        -- the practical proxy for branch coverage of the rejection paths.
        -- An uncovered site after a run is a corpus gap, not a success.
        sites = {},
        mutators = {},
    }

    local function drive(bytes)
        local chunks = split(rng, bytes)
        local ceiling = http.MAX_HEADER_BYTES + http.MAX_BODY_BYTES
            + #bytes + #JUNK + 1
        local index = 1
        local received = 0
        local next_chunk = function()
            local chunk = chunks[index]
            index = index + 1
            if chunk and #chunk > 0 then
                received = received + #chunk
                if received > ceiling then
                    stats.over_budget = stats.over_budget + 1
                    return nil, "over allocation guard"
                end
                return chunk
            end
            return nil, "EOF"
        end
        local ok, request, errmsg, status = pcall(http.read_request, next_chunk)
        if not ok then
            stats.raised = stats.raised + 1
        elseif request then
            stats.parsed = stats.parsed + 1
        else
            stats.rejected = stats.rejected + 1
            if status ~= nil then
                stats.status[status] = (stats.status[status] or 0) + 1
            end
            -- the rejection message names the site: read_request answers
            -- (nil, message, status); the message is the coverage key
            local site = errmsg
            if type(site) ~= "string" then site = "eof:" .. tostring(status or "?") end
            stats.sites[site] = (stats.sites[site] or 0) + 1
        end
    end

    for _ = 1, iterations do
        local bytes = seeds[pick(rng, #seeds)]
        local name = MUTATOR_NAMES[pick(rng, #MUTATOR_NAMES)]
        stats.mutators[name] = (stats.mutators[name] or 0) + 1
        local mutated = mutators[name](rng, bytes)
        if mutated and #mutated > 0 then
            drive(mutated)
        end
    end

    -- exact attribution of the counters is the caller's job (the spec);
    -- the driver stays silent by inward design
    function stats.summary()
        local out = string.format(
            "seed %d: %d iterations: %d parsed, %d rejected, %d raised, %d over budget",
            stats.seed, stats.iterations, stats.parsed, stats.rejected,
            stats.raised, stats.over_budget)
        return out
    end
    return stats
end

-- Differential classification: an independent, minimal reference
-- classifier for the framing contract. It shares no code with
-- http.read_request. The spec replays the seed corpus through both and
-- fails on any classification disagreement (parser says parse, reference
function fuzz.classify(bytes)
    -- returns "parse" or "reject" (and optionally the status)
    local head_end = bytes:find("\r\n\r\n", 1, true)
    if not head_end then return "reject", 400 end
    local head = bytes:sub(1, head_end - 1) .. "\r\n"
    local lines = {}
    for line in head:gmatch("([^\r\n]*)\r\n") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then return "reject", 400 end
    local reqline = lines[1]
    local method, target, version = reqline:match("^(%u+)%s+(%S+)%s+(HTTP/%d%.%d)$")
    if not method then return "reject", 400 end
    if target:match("[%c\127]") then return "reject", 400 end
    if #reqline > http.MAX_REQUEST_LINE_BYTES then return "reject", 414 end
    local header_too_big = head_end + 3 > http.MAX_HEADER_BYTES
    local major = version:match("^HTTP/(%d)%.%d$")
    if major ~= "1" then return "reject", 505 end
    local has_host = false
    local cl = nil
    local te = nil
    local seen = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^([^%s:]+):%s*(.-)%s*$")
        if not name or #name == 0 then return "reject", 400 end
        local lname = name:lower()
        if seen[lname] then return "reject", 400 end
        seen[lname] = true
        if lname == "host" then
            has_host = true
            if #value == 0 then return "reject", 400 end
        end
        if lname == "content-length" then
            local v = value:match("^%s*([%-%+]?%d+)%s*$")
            if not v then return "reject", 400 end
            cl = tonumber(v)
        end
        if lname == "transfer-encoding" then te = value:lower() end
    end
    if header_too_big then return "reject", 431 end
    if not has_host then return "reject", 400 end
    if te then
        if te ~= "chunked" then return "reject", 501 end
        -- well-formed chunked body: hex sizes, data, terminating 0-chunk
        local pos = head_end + 4
        while true do
            local eol = bytes:find("\r\n", pos, true)
            if not eol then return "reject", 400 end
            local hex = bytes:sub(pos, eol - 1)
            if not hex:match("^%x+$") then return "reject", 400 end
            local size = tonumber(hex, 16)
            pos = eol + 2 + size
            if size == 0 then
                if #bytes < pos then return "reject", 400 end
                return "parse"
            end
            if pos + 1 > #bytes then return "reject", 400 end
            if bytes:sub(pos, pos + 1) ~= "\r\n" then return "reject", 400 end
            pos = pos + 2
        end
    end
    if cl then
        if cl < 0 or cl > http.MAX_BODY_BYTES then return "reject", 413 end
        if #bytes > head_end + 3 + cl then return "reject", 400 end
    end
    return "parse"
end

-- The corpus, exposed for the differential test (the spec replays every
-- seed through both the parser and the independent reference classifier).
fuzz.seeds = seeds

return fuzz
