-- Expectation spec for the Http11Probe rig (ext/http/Dockerfile.http).
--
-- The rig is docker-only, so the full probe run is not part of the
-- busted gate. What the gate pins instead is the COMMITTED RUN under
-- ext/http/:
--   probe-manifest.lua   the run's expectation manifest (generated
--                        inside the image: an sha256 block per http
--                        module file, the summary count and one
--                        verdict/status entry per probe test)
--   probe-results.json   the raw responses of that same run (review
--                        record, not asserted here)
--   probe_allowlist.lua  the by-design outcomes, one entry per non-Pass
--                        id, each with its rationale family
--
-- When ext/http changes, the hash test below fails with the regenerate
-- instruction; a regenerated manifest whose outcomes shifted must have
-- the allowlist kept in step (the consistency tests fail otherwise).

describe("http probe expectations", function()
  local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"
  package.preload["lunet.sodium"] = function()
    return assert(loadfile(spec_dir .. "/../ext/crypto/sodium.lua"))()
  end

  local ok, sodium = pcall(require, "lunet.sodium")
  if not ok then
    pending("lunet.sodium not built (xmake build-paxe)", function() end)
    return
  end

  local manifest = assert(dofile(spec_dir .. "/../ext/http/probe-manifest.lua"))
  local allowlist = assert(dofile(spec_dir .. "/../ext/http/probe_allowlist.lua"))

  local REGENERATE =
    "dev-tree ext/http no longer matches the committed probe manifest; regenerate:\n" ..
    "  docker build -f ext/http/Dockerfile.http -t lunet-http-probe .\n" ..
    "  docker run --rm -v \"$(pwd)/ext/http:/out\" lunet-http-probe\n" ..
    "then keep ext/http/probe_allowlist.lua in step and commit all three artifacts."

  local function file_digest(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    local digest = assert(sodium.sha256(data))
    return (digest:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end

  -- The allowlist zero-trusts the manifest: pinned verdict and status
  -- must both equal what the run recorded.
  local function pins_match(pinned, recorded)
    return pinned.verdict == recorded.verdict and pinned.status == recorded.status
  end

  local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
  end

  it("manifest modules match the dev tree (manifest is fresh)", function()
    local stale = {}
    for name, digest in pairs(manifest.modules) do
      if file_digest(spec_dir .. "/../ext/http/" .. name) ~= digest then
        stale[#stale + 1] = name
      end
    end
    assert.equals(0, #stale, REGENERATE)
  end)

  it("manifest covers every test of the committed run", function()
    assert.equals(manifest.total, count(manifest.results))
    assert.is_true(manifest.total > 0)
  end)

  it("every allowlist entry matches the manifest (one check per id)", function()
    for id, pinned in pairs(allowlist) do
      local recorded = assert(manifest.results[id],
        "allowlist id not in the manifest: " .. id .. "; regenerate the manifest")
      assert.is_true(pins_match(pinned, recorded),
        "probe outcome drifted for " .. id .. "\n" .. REGENERATE)
    end
  end)

  it("every non-Pass verdict in the manifest is allowlisted", function()
    for id, recorded in pairs(manifest.results) do
      if recorded.verdict ~= "Pass" then
        local pinned = allowlist[id]
        assert(pinned ~= nil,
          "unblocked probe outcome for " .. id
          .. ": add it (with its by-design rationale) to ext/http/probe_allowlist.lua\n" .. REGENERATE)
        assert.is_true(pins_match(pinned, recorded),
          "probe outcome drifted for " .. id .. "\n" .. REGENERATE)
      end
    end
  end)
end)
