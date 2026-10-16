describe("sqlite3 module #native", function()
  local ok, db = pcall(require, "lunet.sqlite3")
  if not ok then
    pending("lunet.sqlite3 not built (xmake build lunet-sqlite3)", function() end)
    return
  end

  it("exports the driver surface", function()
    assert.are.equal("table", type(db))
    for _, fn in ipairs({ "open", "close", "query", "exec", "query_params", "exec_params" }) do
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

  describe("pool_size validation", function()
    local function open_error(params)
      local co = coroutine.create(function()
        return db.open(params)
      end)
      local resumed, err = coroutine.resume(co)
      return resumed, err
    end

    it("rejects a non-integer pool_size", function()
      local resumed, err = open_error({ path = "spec_pool.db", pool_size = "two" })
      assert.is_false(resumed)
      assert.matches("pool_size", tostring(err))
    end)

    it("rejects pool_size below 1", function()
      local resumed, err = open_error({ path = "spec_pool.db", pool_size = 0 })
      assert.is_false(resumed)
      assert.matches("pool_size", tostring(err))
    end)

    it("rejects pool_size above the cap", function()
      local resumed, err = open_error({ path = "spec_pool.db", pool_size = 65 })
      assert.is_false(resumed)
      assert.matches("pool_size", tostring(err))
    end)
  end)
end)
