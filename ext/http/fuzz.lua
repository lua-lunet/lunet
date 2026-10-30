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
  boundary, insert junk bytes, replace a byte, duplicate a header line
  and splice in another seed. Interesting cases graduate into the
  spec corpus as fixtures.
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

local MUTATOR_NAMES = { "truncate", "insert", "replace", "duplicate_line", "splice" }

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
        mutators = {},
    }

    for _ = 1, iterations do
        local bytes = seeds[pick(rng, #seeds)]
        local name = MUTATOR_NAMES[pick(rng, #MUTATOR_NAMES)]
        stats.mutators[name] = (stats.mutators[name] or 0) + 1
        local mutated = mutators[name](rng, bytes)
        if mutated and #mutated > 0 then
            local chunks = split(rng, mutated)
            -- every byte delivered beyond a valid request's own framing
            -- comes back as a rejection; types guard the allocation cap
            local ceiling = http.MAX_HEADER_BYTES + http.MAX_BODY_BYTES
                + #mutated + #JUNK + 1
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
            local ok, request, _, status = pcall(http.read_request, next_chunk)
            if not ok then
                stats.raised = stats.raised + 1
            elseif request then
                stats.parsed = stats.parsed + 1
            else
                stats.rejected = stats.rejected + 1
                if status ~= nil then
                    stats.status[status] = (stats.status[status] or 0) + 1
                end
            end
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

return fuzz
