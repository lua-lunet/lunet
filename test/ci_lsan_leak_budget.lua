-- LeakSanitizer budget gate for CI.
--
-- Motivation:
-- - In some CI environments, loading libmysqlclient can trigger a small,
--   stable set of one-time allocations in libstdc++/runtime init paths that
--   LeakSanitizer reports at process exit.
-- - These allocations are outside lunet's control and may not be freed even
--   after calling mysql_library_end().
--
-- Strategy:
-- - Force LSAN to not fail the process (LSAN_OPTIONS=exitcode=0)
-- - Parse the log output and enforce a strict budget.
-- - Default budget is 4 allocations (or 0 allocations).
--
-- Usage:
--   luajit test/ci_lsan_leak_budget.lua /path/to/lsan.log
--
-- Configure via:
--   LSAN_LEAK_BUDGET_ALLOCS=4

local log_path = arg[1]
if not log_path or #log_path == 0 then
  io.stderr:write("usage: luajit test/ci_lsan_leak_budget.lua <lsan_log_path>\n")
  os.exit(2)
end

local f = io.open(log_path, "rb")
if not f then
  io.stderr:write("ci_lsan_leak_budget: could not open log: " .. tostring(log_path) .. "\n")
  os.exit(2)
end
local data = f:read("*a") or ""
f:close()

-- Strip ANSI color codes if present.
data = data:gsub("\27%[[%d;]*m", "")

local budget = tonumber(os.getenv("LSAN_LEAK_BUDGET_ALLOCS") or "4") or 4

-- Parse the standard ASAN leak summary line.
local bytes, allocs =
  data:match("SUMMARY:%s+AddressSanitizer:%s+(%d+)%s+byte%(s%)%s+leaked%s+in%s+(%d+)%s+allocation%(s%)%.")
if bytes and allocs then
  bytes, allocs = tonumber(bytes) or 0, tonumber(allocs) or 0
else
  bytes, allocs = 0, 0
end

local saw_lsan = data:find("LeakSanitizer: detected memory leaks", 1, true) ~= nil

-- If LSAN claimed leaks but we couldn't parse a summary, be conservative.
if saw_lsan and allocs == 0 then
  io.stderr:write("[LSAN_BUDGET][FAIL] LSAN reported leaks but summary parsing failed.\n")
  os.exit(1)
end

if allocs == 0 then
  print(string.format("[LSAN_BUDGET][OK] no leaks detected (budget=%d allocs)", budget))
  os.exit(0)
end

if allocs == budget then
  print(string.format("[LSAN_BUDGET][OK] leak budget met: %d bytes in %d allocs (budget=%d allocs)", bytes, allocs, budget))
  os.exit(0)
end

io.stderr:write(string.format("[LSAN_BUDGET][FAIL] leak budget exceeded: %d bytes in %d allocs (budget=%d allocs)\n", bytes, allocs, budget))
os.exit(1)

