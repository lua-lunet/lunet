-- repro_bug06 + repro_bug07: make clean wrong dir; unquoted mkdir.
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local C = dofile(script_dir .. "/common.lua")

local root = C.repo_root()
local bin = C.lunet_bin(root)
local ev_dir = root .. "/.tmp/bug_repro"
os.execute("mkdir -p " .. C.quote(ev_dir))

-- BUG-6: config at repo root, then make clean from the example dir.
local cfg = root .. "/.tmp/advisory_lock_config.lua"
assert(os.execute(bin .. " " .. root
    .. "/examples/advisory_lock_cas/config_gen.lua --output " .. cfg) == 0)
local existed_before = io.open(cfg, "r") ~= nil
os.execute("make -C " .. C.quote(root .. "/examples/advisory_lock_cas") .. " clean >/dev/null 2>&1")
local still_there = io.open(cfg, "r") ~= nil

-- BUG-7: spacey --output path (inside .tmp sandbox, unique per run).
local spacey_dir = root .. "/.tmp/a b " .. os.time()
local spacey = spacey_dir .. "/cfg.lua"
os.execute(bin .. " " .. root .. "/examples/advisory_lock_cas/config_gen.lua --output "
    .. C.quote(spacey))
local right_exists = io.open(spacey, "r") ~= nil
local wrong_a = io.open(root .. "/.tmp/a", "r") ~= nil
local wrong_b_dir = io.open("b", "r") ~= nil

local f = assert(io.open(ev_dir .. "/bug06_07.log", "w"))
f:write("BUG-6: repo-root config existed before clean: ", tostring(existed_before),
    "; still there after clean: ", tostring(still_there),
    still_there and "  <- OBSERVED: clean missed it\n" or "\n")
f:write("BUG-7: --output '", spacey, "' -> file at correct path: ", tostring(right_exists),
    "; stray .tmp/a: ", tostring(wrong_a),
    "; stray ./b: ", tostring(wrong_b_dir),
    (wrong_a or wrong_b_dir) and "  <- OBSERVED: unquoted mkdir\n" or "\n")
f:close()
print("evidence: " .. ev_dir .. "/bug06_07.log")
os.exit(0)
