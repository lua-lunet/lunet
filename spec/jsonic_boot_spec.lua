-- Pins the eager native-library load at require time: ext/jsonic/jsonic.lua
-- calls ffi.load(find_lib()) while the module chunk executes, so a missing
-- liblunet_jsonic raises before any decode is attempted. The loader is
-- exercised from a scratch copy (no candidate library beside it) so the
-- find_lib diagnostic fires deterministically regardless of whether the
-- real cdylib has been built in the dev tree.
describe("jsonic boot-time load #native", function()
  it("raises when liblunet_jsonic cannot be found", function()
    local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"
    local root = spec_dir .. "/../.tmp/jsonic_boot"
    os.execute("mkdir -p " .. root)

    local function copy(src, dst)
      local f = assert(io.open(src, "rb"))
      local data = f:read("*a")
      f:close()
      local g = assert(io.open(dst, "wb"))
      g:write(data)
      g:close()
    end
    copy(spec_dir .. "/../ext/jsonic/jsonic.lua", root .. "/jsonic.lua")
    copy(spec_dir .. "/../ext/jsonic/dkjson-encode-v2.10.lua",
         root .. "/dkjson-encode-v2.10.lua")

    local ffi = require("ffi")
    ffi.cdef[[int setenv(const char*, const char*, int); int unsetenv(const char*);]]
    local prev = os.getenv("LUNET_JSONIC_LIB")
    ffi.C.unsetenv("LUNET_JSONIC_LIB")

    local ok, err = pcall(function()
      return assert(loadfile(root .. "/jsonic.lua"))()
    end)

    if prev then ffi.C.setenv("LUNET_JSONIC_LIB", prev, 1) end

    assert.is_false(ok)
    assert.matches("cannot find liblunet_jsonic", tostring(err))
  end)
end)