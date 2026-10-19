-- Gate-integrated fuzz spec: drives ext/http/fuzz.lua (the seeded corpus
-- fuzzer over http.read_request) with a fixed budget and seeds. The
-- driver is deterministic, so a failure here is replayable with the seed
-- it reports. New fuzzer findings graduate into spec corpus fixtures;
-- this file pins only the envelope contract (no crash, no hang, no
-- oversize allocation, framing-subset statuses, replayability).

describe("http frame fuzzer", function()
  local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"
  package.preload["lunet.http"] = function()
    return assert(loadfile(spec_dir .. "/../ext/http/http.lua"))()
  end

  local ok_http = pcall(require, "lunet.http")
  if not ok_http then
    pending("lunet.http loader not found (ext/http/http.lua)", function() end)
    return
  end
  package.preload["lunet.http_fuzz"] = function()
    return assert(loadfile(spec_dir .. "/../ext/http/fuzz.lua"))()
  end
  local ok_fuzz, fuzz = pcall(require, "lunet.http_fuzz")
  if not ok_fuzz then
    pending("lunet.http_fuzz loader not found (ext/http/fuzz.lua)", function() end)
    return
  end

  local STATUS = { [400] = true, [413] = true, [414] = true,
                   [431] = true, [501] = true, [505] = true }

  local function assert_contract(stats)
    assert.equals(0, stats.raised,
      "read_request raised on the fuzz stream; replay seed " .. stats.seed
      .. " via fuzz.run({ seed = " .. stats.seed .. ", budget = " .. stats.iterations .. " })")
    assert.equals(0, stats.over_budget,
      "reader consumed fewer than the allocation guard permits; seed " .. stats.seed)
    for status in pairs(stats.status) do
      assert.is_true(STATUS[status] == true,
        "rejection outside the framing subset status map: " .. tostring(status)
        .. " (seed " .. stats.seed .. ")")
    end
  end

  it("contracts hold over a seeded budget", function()
    for _, seed in ipairs({ 0x9e3779b9, 0x51ed270b, 0x2545f491 }) do
      local stats = fuzz.run({ seed = seed, budget = 400 })
      assert_contract(stats)
      assert.is_true(stats.parsed > 0 and stats.rejected > 0,
        "a healthy corpus parses and rejects (seed " .. seed .. ")")
    end
  end)

  it("a seed replays byte-identical counters", function()
    local a, b = fuzz.run({ seed = 0x9e3779b9, budget = 400 }),
                 fuzz.run({ seed = 0x9e3779b9, budget = 400 })
    assert.equals(a.parsed, b.parsed)
    assert.equals(a.rejected, b.rejected)
    assert.equals(a.raised, b.raised)
    assert.equals(a.over_budget, b.over_budget)
    for _, name in ipairs({ "truncate", "insert", "replace", "duplicate_line", "splice" }) do
      assert.equals(a.mutators[name], b.mutators[name])
      assert.is_true(a.mutators[name] > 0, name .. " fired at least once")
    end
  end)
end)
