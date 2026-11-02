-- Gate-integrated fuzz spec: drives ext/http/fuzz.lua (the seeded corpus
-- fuzzer over http.read_request) with a fixed budget and seeds. The
-- driver is deterministic, so a failure here is replayable with the seed
-- it reports. New fuzzer findings graduate into spec corpus fixtures;
-- this file pins only the envelope contract (no crash, no hang, no
-- oversize allocation, framing-subset statuses, replayability), the
-- rejection-site coverage (an uncovered site is a corpus gap), the
-- cap-boundary fixtures (admit at the limit, refuse one past), and the
-- differential classification against an independent reference.

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
  local http = require("lunet.http")

  local STATUS = { [400] = true, [413] = true, [414] = true,
                   [431] = true, [501] = true, [505] = true }

  -- Rejection sites REACHABLE through read_request (the chunk-body
  -- sites live behind the body-reading functions, not this entry
  -- point). Every one of these must fire across the seeded run plus
  -- the cap-boundary fixtures: an uncovered site is a corpus gap.
  local REACHABLE_SITES = {
    "Invalid HTTP request",
    "Invalid HTTP header",
    "Invalid Content-Length",
    "Missing Host header",
    "Duplicate HTTP header",
    "Unexpected data after request body",
    "Request line too long",
    "Request headers too large",
    "Request body too large",
    "HTTP version not supported",
    "Transfer-Encoding is not supported",
  }

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

  it("the committed corpus never shrinks", function()
    -- The corpus only grows: findings graduate in, nothing is removed.
    assert.is_true(#fuzz.seeds >= 22,
      "the committed corpus shrank: " .. #fuzz.seeds)
  end)

  it("contracts hold over a seeded budget", function()
    -- Budget and seed are env-overridable for the nightly unseeded leg:
    -- LUNET_FUZZ_BUDGET (bigger budget) and LUNET_FUZZ_SEED (defaults to
    -- the wall clock there, so the nightly explores; the printed seed
    -- replays any failure deterministically). The gate stays fixed.
    local budget = tonumber(os.getenv("LUNET_FUZZ_BUDGET")) or 400
    local nightly_seed = os.getenv("LUNET_FUZZ_SEED")
    local seeds
    if nightly_seed then
      seeds = { tonumber(nightly_seed) % 4294967296 }
    else
      seeds = { 0x9e3779b9, 0x51ed270b, 0x2545f491 }
    end
    for _, seed in ipairs(seeds) do
      local stats = fuzz.run({ seed = seed, budget = budget })
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
    for _, name in ipairs({ "truncate", "insert", "replace", "duplicate_line",
                            "splice", "method_token", "version_token",
                            "cl_value", "header_name" }) do
      assert.equals(a.mutators[name], b.mutators[name])
      assert.is_true(a.mutators[name] > 0, name .. " fired at least once")
    end
  end)

  it("every reachable rejection site is covered (corpus gap check)", function()
    local covered = {}
    for _, seed in ipairs({ 0x9e3779b9, 0x51ed270b, 0x2545f491 }) do
      local stats = fuzz.run({ seed = seed, budget = 400 })
      for site in pairs(stats.sites) do
        covered[site] = true
      end
    end
    -- the cap-boundary fixtures guarantee the cap sites regardless of
    -- what the random walk happens to hit
    local fx = fuzz.cap_boundary_fixtures()
    local function classify_bytes(bytes)
      local index, received = 1, 0
      local ceiling = http.MAX_HEADER_BYTES + http.MAX_BODY_BYTES + #bytes + 2
      local next_chunk = function()
        local chunk = bytes:sub(index, index + 4095)
        index = index + 4096
        if chunk and #chunk > 0 then
          received = received + #chunk
          if received > ceiling then return nil, "over" end
          return chunk
        end
        return nil, "EOF"
      end
      local ok, request, errmsg, status = pcall(http.read_request, next_chunk)
      if ok and request then
        return "parse", errmsg
      end
      return "reject", errmsg or ("eof:" .. tostring(status))
    end
    for _, bytes in ipairs({ fx.line_past, fx.header_past, fx.body_past,
                             fx.line_at, fx.header_at, fx.body_at }) do
      local _, site = classify_bytes(bytes)
      if site then covered[site] = true end
    end
    for _, site in ipairs(REACHABLE_SITES) do
      assert.is_true(covered[site] == true,
        "rejection site never exercised - a corpus gap: " .. site)
    end
  end)

  describe("cap boundaries (live caps values)", function()
    local fx = fuzz.cap_boundary_fixtures()
    local function deliver(bytes)
      local index, received = 1, 0
      local ceiling = http.MAX_HEADER_BYTES + http.MAX_BODY_BYTES + #bytes + 2
      local next_chunk = function()
        local chunk = bytes:sub(index, index + 4095)
        index = index + 4096
        if chunk and #chunk > 0 then
          received = received + #chunk
          if received > ceiling then return nil, "over" end
          return chunk
        end
        return nil, "EOF"
      end
      local ok, request, errmsg, status = pcall(http.read_request, next_chunk)
      return ok, request, errmsg, status
    end

    it("admits a request line at MAX_REQUEST_LINE_BYTES", function()
      assert.is_true(fx.line_at ~= nil, "fixture generation failed")
      local ok, request = deliver(fx.line_at)
      assert.is_true(ok and request ~= nil,
        "a request line AT the cap must parse (got " .. tostring(ok) .. ")")
    end)

    it("refuses a request line one past with 414", function()
      local ok, request, _, status = deliver(fx.line_past)
      assert.is_true(ok and request == nil and status == 414,
        "one byte past the line cap must reject 414")
    end)

    it("admits a header section at MAX_HEADER_BYTES", function()
      assert.is_true(fx.header_at ~= nil, "fixture generation failed")
      local ok, request = deliver(fx.header_at)
      assert.is_true(ok and request ~= nil,
        "a header section AT the cap must parse (got " .. tostring(ok) .. ")")
    end)

    it("refuses a header section one past with 431", function()
      local ok, request, _, status = deliver(fx.header_past)
      assert.is_true(ok and request == nil and status == 431,
        "one byte past the header cap must reject 431")
    end)

    it("admits a body at MAX_BODY_BYTES", function()
      local ok, request = deliver(fx.body_at)
      assert.is_true(ok and request ~= nil,
        "a body AT the cap must parse (got " .. tostring(ok) .. ")")
    end)

    it("refuses a body one past with 413", function()
      local ok, request, _, status = deliver(fx.body_past)
      assert.is_true(ok and request == nil and status == 413,
        "one byte past the body cap must reject 413")
    end)
  end)

  describe("differential classification", function()
    -- The reference classifier shares no code with the parser: where the
    -- two disagree on the CLASS (parse vs reject) over the corpus, the
    -- disagreement is the finding.
    local function parser_class(bytes)
      local index = 1
      local ceiling = http.MAX_HEADER_BYTES + http.MAX_BODY_BYTES + #bytes + 2
      local next_chunk = function()
        local chunk = bytes:sub(index, index + 4095)
        index = index + 4096
        if chunk and #chunk > 0 then
          return chunk
        end
        return nil, "EOF"
      end
      local ok, request = pcall(http.read_request, next_chunk)
      if ok and request then return "parse" end
      return "reject"
    end

    it("reference and parser agree on every corpus seed", function()
      for _, bytes in ipairs(fuzz.seeds) do
        local ref_class = fuzz.classify(bytes)
        local got_class = parser_class(bytes)
        assert.equals(ref_class, got_class,
          "differential disagreement on corpus seed: "
          .. bytes:sub(1, 40):gsub("\r\n", "|"))
      end
    end)

    it("reference and parser agree on every cap-boundary fixture", function()
      local fx = fuzz.cap_boundary_fixtures()
      for name, bytes in pairs(fx) do
        local ref_class = fuzz.classify(bytes)
        local got_class = parser_class(bytes)
        assert.equals(ref_class, got_class,
          "differential disagreement on fixture " .. tostring(name))
      end
    end)
  end)
end)
