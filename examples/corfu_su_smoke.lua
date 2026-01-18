local lunet = require('lunet')
local su_mod = require('lunet.su')

lunet.spawn(function()
  local su, err = su_mod.open("./corfu_su_smoke", 1024)
  if not su then error(err) end

  local block = string.rep("A", 4096)
  local ok, werr = su:write_once(7, block)
  assert(ok and not werr, werr)

  local data, rerr = su:read(7)
  assert(data == block, rerr)

  local ok2, werr2 = su:write_once(7, block)
  assert(not ok2 and werr2 == "ALREADY_WRITTEN", "expected ALREADY_WRITTEN, got: " .. tostring(werr2))

  su:close()
end)

