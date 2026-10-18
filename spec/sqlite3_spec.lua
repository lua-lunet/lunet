describe("sqlite3 module #native", function()
  local ok, db = pcall(require, "lunet.sqlite3")
  if not ok then
    pending("lunet.sqlite3 not built (xmake build lunet-sqlite3)", function() end)
    return
  end

  it("exports the driver surface", function()
    assert.are.equal("table", type(db))
    for _, fn in ipairs({ "open", "open_raw", "destroy", "close", "query", "exec",
                          "query_params", "exec_params", "prepare" }) do
      assert.are.equal("function", type(db[fn]))
    end
  end)

  it("requires calling open from a coroutine", function()
    -- The driver guards on running inside the runtime's coroutines before
    -- validating arguments; outside one it errors instead of returning.
    assert.has_error(function()
      db.open({ path = "sqlite3_spec_should_not_exist.db" })
    end)
  end)

  it("requires calling open_raw from a coroutine", function()
    assert.has_error(function()
      db.open_raw({ path = "sqlite3_spec_should_not_exist.db" })
    end)
  end)

  it("requires a params table to open", function()
    local co = coroutine.create(function()
      return db.open("not-a-table")
    end)
    -- db.open raises (lua_error) rather than returning nil, err, so resume
    -- reports the coroutine as failed with the message.
    local resumed, err = coroutine.resume(co)
    assert.is_false(resumed)
    assert.is_truthy(err)
  end)

  it("destroy on a never-opened path is a no-op", function()
    -- destroy is the Lua loader's cache miss + close: with no cache entry
    -- it touches no C function and needs no runtime.
    assert.has_no_error(function()
      db.destroy("sqlite3_spec_never_opened.db")
    end)
  end)

  describe("prepare validation", function()
    it("requires calling prepare from a coroutine", function()
      -- The driver guards on running inside the runtime's coroutines
      -- before validating arguments; outside one it errors instead of
      -- returning.
      assert.has_error(function()
        db.prepare(nil, "SELECT 1")
      end)
    end)

    it("rejects empty SQL", function()
      local co = coroutine.create(function()
        return db.prepare(nil, "")
      end)
      local resumed, err = coroutine.resume(co)
      assert.is_false(resumed)
      assert.matches("prepare", tostring(err))
    end)
  end)
end)
