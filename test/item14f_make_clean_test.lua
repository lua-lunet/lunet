-- RED PHASE (item14): make clean must remove repo-root artifacts. Fails
-- until item19 (Makefile fix). BUG-6.
-- Usage (after rework): lunet-run test/item14f_make_clean_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()
local cfg = root .. "/.tmp/advisory_lock_config.lua"

local t = H.new_tally()

lunet.spawn(function()
    assert(H.run_config_gen(bin, cfg), "config_gen failed")
    t.check(H.file_exists(cfg), "repo-root config exists before clean")

    local ok = H.run_ok("make -C " .. H.quote(root .. "/examples/advisory_lock_cas")
        .. " clean >/dev/null 2>&1")
    t.check(ok, "make clean exits 0")
    t.check(not H.file_exists(cfg),
        "repo-root config removed by make clean")

    t.exit()
end)
