-- lunet.paxe: LuaJIT FFI loader for the lunet-paxe Rust cdylib.
--
-- Scaffold only: mirrors the loading model of ext/jsonic/jsonic.lua and
-- exposes just version(). The real API surface is item07.

local ffi = require("ffi")

ffi.cdef[[
  const char* lunet_paxe_version(void);
]]

local function find_lib()
  local env = os.getenv("LUNET_PAXE_LIB")
  if env and env ~= "" then return env end
  local suffix, prefix = "so", "lib"
  if package.config:sub(1, 1) == "\\" then
    -- Windows: the cdylib is lunet_paxe.dll (no "lib" prefix)
    suffix, prefix = "dll", ""
  else
    local ok_popen, uname = pcall(io.popen, "uname -s 2>/dev/null")
    if ok_popen and uname then
      local sys = uname:read("*l") or ""
      uname:close()
      if sys == "Darwin" then suffix = "dylib" end
    end
  end
  local script = debug.getinfo(2, "S").source
  local dir = script:match("^@(.+)/[^/]+$") or "."
  for _, p in ipairs({
    dir .. "/target/release/" .. prefix .. "lunet_paxe." .. suffix,
    dir .. "/" .. prefix .. "lunet_paxe." .. suffix,
  }) do
    local f = io.open(p, "rb")
    if f then f:close(); return p end
  end
  error("lunet.paxe: cannot find " .. prefix .. "lunet_paxe." .. suffix, 3)
end

local _lib
local function lib()
  if not _lib then _lib = ffi.load(find_lib()) end
  return _lib
end

local M = {}

function M.version()
  return ffi.string(lib().lunet_paxe_version())
end

return M
