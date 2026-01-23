describe("C safety lint", function()
  it("passes on the current tree", function()
    local ok = os.execute("lua bin/lint_c_safety.lua >/dev/null 2>&1")
    -- LuaJIT returns true on success.
    assert.is_true(ok)
  end)
end)
