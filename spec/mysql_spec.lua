describe("mysql module #native", function()
  local ok, mysql = pcall(require, "lunet.mysql")
  if not ok then
    pending("lunet.mysql not built (xmake build lunet-mysql)", function() end)
    return
  end

  it("exports the driver surface", function()
    assert.are.equal("table", type(mysql))
    for _, fn in ipairs({ "open", "close", "query", "exec", "query_params", "exec_params" }) do
      assert.are.equal("function", type(mysql[fn]))
    end
  end)

  describe("pool_size validation", function()
    local function open_error(params)
      local co = coroutine.create(function()
        return mysql.open(params)
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
        return mysql.open(params)
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
  end)
end)
