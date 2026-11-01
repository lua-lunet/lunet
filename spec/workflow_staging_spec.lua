-- Guards the release/build workflow staging lists against rot: every
-- static path the workflows reference must exist in the tree. Platform-
-- variant build artifacts (target/release/*) are exempt — each is produced
-- by the workflow's own build steps on its own runner, so a missing local
-- copy is expected, not stale. This check exists because release.yml once
-- staged ext/paxe/sodium.lua for months after the file moved to ext/crypto,
-- and both the staging failure and the missing crypto build were only
-- visible in CI logs.
describe("workflow staging paths", function()
  it("references only paths that exist in the tree", function()
    local workflows = {}
    for _, name in ipairs({ "build.yml", "release.yml" }) do
      table.insert(workflows, ".github/workflows/" .. name)
    end

    -- Repo root: this spec lives in <root>/spec/.
    local root = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
    root = root .. "/.."

    local missing = {}
    for _, wf in ipairs(workflows) do
      local fh = assert(io.open(root .. "/" .. wf, "r"), "cannot open " .. wf)
      local body = fh:read("*a")
      fh:close()

      -- Scan command lines only: drop full-line comments, whose prose may
      -- legitimately mention paths that are descriptions, not staging ops.
      local commands = {}
      for ln in body:gmatch("[^\r\n]+") do
        if not ln:match("^%s*#") then
          table.insert(commands, ln)
        end
      end
      body = table.concat(commands, "\n")

      -- Static tree paths the workflow copies/stages: ext/..., docs/...,
      -- include/..., bin/..., examples/..., types/... (Lua patterns have
      -- no alternation, so one pass per prefix.)
      for _, prefix in ipairs({ "ext", "docs", "include", "bin", "examples", "types" }) do
        for path in body:gmatch(prefix .. "/[A-Za-z0-9_./%-]+") do
          -- Skip platform-variant artifacts and directory globs.
          if not path:find("target/release/", 1, true) then
            local full = root .. "/" .. path
            local f = io.open(full, "r")
            if f then
              f:close()
            else
              table.insert(missing, wf .. ": " .. path)
            end
          end
        end
      end
    end

    assert.is_true(#missing == 0,
      "workflow staging references missing paths:\n  " .. table.concat(missing, "\n  "))
  end)
end)
