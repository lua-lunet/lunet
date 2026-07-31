-- RED PHASE (item14): config_gen must quote its mkdir. Fails until
-- item17. BUG-7: a spacey --output path must not create stray dirs.
-- Usage (after rework): lunet-run test/item14g_mkdir_quote_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local bin = H.find_lunet_bin()

local t = H.new_tally()

lunet.spawn(function()
    local spacey_dir = root .. "/.tmp/q t " .. os.time()
    local spacey = spacey_dir .. "/cfg.lua"
    local ok = H.run_ok(bin .. " " .. root
        .. "/examples/advisory_lock_cas/config_gen.lua --output " .. H.quote(spacey))
    t.check(ok, "config_gen exits 0 on spacey path")
    t.check(H.file_exists(spacey), "config created at the exact spacey path")

    -- No stray dirs from an unquoted split: ".tmp/q" would be a stray top
    -- level fragment, as would a CWD-local "t".
    t.check(not H.file_exists(root .. "/.tmp/q"), "no stray .tmp/q dir")
    t.check(not H.file_exists("t"), "no stray CWD-local t dir")

    os.remove(spacey)
    H.run_ok("rmdir " .. H.quote(spacey_dir) .. " 2>/dev/null")
    t.exit()
end)
