-- fuzz-nightly.lua - the nightly unseeded fuzz leg, run through the
-- ASan + easy-memory instrumented runtime (lunet-run) so oversize
-- allocation and RSS misbehaviour count as findings alongside the
-- parser contract.
--
-- Usage: lunet-run bin/fuzz-nightly.lua
-- Env:   LUNET_FUZZ_SEED   (default: wall clock; printed for replay)
--        LUNET_FUZZ_BUDGET (default 50000)

local fuzz = require("ext.http.fuzz") or dofile("ext/http/fuzz.lua")
local http = dofile("ext/http/http.lua")

local seed = tonumber(os.getenv("LUNET_FUZZ_SEED") or "")
if not seed then
    seed = os.time() % 4294967296
    if seed == 0 then seed = 1 end
end
local budget = tonumber(os.getenv("LUNET_FUZZ_BUDGET") or "") or 50000

print(string.format("fuzz-nightly: seed %d budget %d (replay with LUNET_FUZZ_SEED=%d)",
    seed, budget, seed))

local STATUS = { [400] = true, [413] = true, [414] = true,
                 [431] = true, [501] = true, [505] = true }

local stats = fuzz.run({ seed = seed, budget = budget })
print(stats:summary())
print(string.format("sites covered: %d", (function()
    local n = 0
    for _ in pairs(stats.sites) do n = n + 1 end
    return n
end)()))

local failed = false
if stats.raised > 0 then
    print("FAIL: read_request raised on the fuzz stream")
    failed = true
end
if stats.over_budget > 0 then
    print("FAIL: allocation guard tripped")
    failed = true
end
for status in pairs(stats.status) do
    if not STATUS[status] then
        print("FAIL: rejection outside the framing subset: " .. tostring(status))
        failed = true
    end
end
if stats.parsed == 0 or stats.rejected == 0 then
    print("FAIL: a healthy corpus parses and rejects")
    failed = true
end

os.exit(failed and 1 or 0)
