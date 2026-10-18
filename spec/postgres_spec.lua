describe("postgres module #native", function()
  local ok, pg = pcall(require, "lunet.postgres")
  if not ok then
    pending("lunet.postgres not built (xmake build lunet-postgres)", function() end)
    return
  end

  it("exports the driver surface", function()
    assert.are.equal("table", type(pg))
    for _, fn in ipairs({ "open", "close", "query", "exec", "query_params", "exec_params" }) do
      assert.are.equal("function", type(pg[fn]))
    end
  end)

  describe("pool_size validation", function()
    local function open_error(params)
      local co = coroutine.create(function()
        return pg.open(params)
      end)
      local resumed, err = coroutine.resume(co)
      return resumed, err
    end

    it("rejects a non-integer pool_size", function()
      local resumed, err = open_error({ host = "127.0.0.1", pool_size = "two" })
      assert.is_false(resumed)
      assert.matches("pool_size", tostring(err))
    end)

    it("rejects pool_size below 1", function()
      local resumed, err = open_error({ host = "127.0.0.1", pool_size = 0 })
      assert.is_false(resumed)
      assert.matches("pool_size", tostring(err))
    end)

    it("rejects pool_size above the cap", function()
      local resumed, err = open_error({ host = "127.0.0.1", pool_size = 65 })
      assert.is_false(resumed)
      assert.matches("pool_size", tostring(err))
    end)
  end)

  describe("open passthrough validation", function()
    local function open_error(params)
      local co = coroutine.create(function()
        return pg.open(params)
      end)
      local resumed, err = coroutine.resume(co)
      return resumed, err
    end

    it("rejects a non-numeric connect_timeout", function()
      local resumed, err = open_error({ host = "127.0.0.1", connect_timeout = "five" })
      assert.is_false(resumed)
      assert.matches("connect_timeout", tostring(err))
    end)

    it("rejects a non-positive connect_timeout", function()
      local resumed, err = open_error({ host = "127.0.0.1", connect_timeout = 0 })
      assert.is_false(resumed)
      assert.matches("connect_timeout", tostring(err))
    end)

    it("rejects a non-string sslmode", function()
      local resumed, err = open_error({ host = "127.0.0.1", sslmode = 42 })
      assert.is_false(resumed)
      assert.matches("sslmode", tostring(err))
    end)

    it("rejects an sslmode libpq does not accept", function()
      local resumed, err = open_error({ host = "127.0.0.1", sslmode = "sometimes" })
      assert.is_false(resumed)
      assert.matches("sslmode", tostring(err))
    end)
  end)
end)
