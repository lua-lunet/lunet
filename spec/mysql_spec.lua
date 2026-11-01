describe("mysql module #native", function()
  local ok, mysql = pcall(require, "lunet.mysql")
  if not ok then
    pending("lunet.mysql not built (mysqlclient >= 8.0 / libmariadb >= 3.4)", function() end)
    return
  end

  it("exports the driver surface", function()
    assert.are.equal("table", type(mysql))
    local surface = { "open", "close", "checkout", "release", "ping", "query",
      "exec", "query_params", "exec_params" }
    for _, fn in ipairs(surface) do
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

  describe("TLS passthrough validation", function()
    -- Validation fires before any connection attempt, so these need no
    -- server. Returns everything coroutine.resume produced: on a raised
    -- validation error (resumed=false, err), on a connect failure
    -- (resumed=true, nil, connect error).
    local function open_result(params)
      local co = coroutine.create(function()
        return mysql.open(params)
      end)
      return coroutine.resume(co)
    end

    it("rejects a non-string ssl_ca", function()
      local resumed, err = open_result({ host = "127.0.0.1", ssl_ca = true })
      assert.is_false(resumed)
      assert.matches("ssl_ca", tostring(err))
    end)

    it("rejects a wrong-typed tls_version", function()
      local resumed, err = open_result({ host = "127.0.0.1", tls_version = 12 })
      assert.is_false(resumed)
      assert.matches("tls_version", tostring(err))
    end)

    it("rejects a non-whitelisted tls_version", function()
      local resumed, err = open_result({ host = "127.0.0.1", tls_version = "TLSv1.1" })
      assert.is_false(resumed)
      assert.matches("tls_version", tostring(err))
    end)

    it("rejects tls_version with whitespace around the comma", function()
      local resumed, err = open_result({ host = "127.0.0.1", tls_version = "TLSv1.2, TLSv1.3" })
      assert.is_false(resumed)
      assert.matches("tls_version", tostring(err))
    end)

    it("rejects an empty tls_version", function()
      local resumed, err = open_result({ host = "127.0.0.1", tls_version = "" })
      assert.is_false(resumed)
      assert.matches("tls_version", tostring(err))
    end)

    it("rejects an invalid ssl_mode value", function()
      local resumed, err = open_result({ host = "127.0.0.1", ssl_mode = "bogus" })
      assert.is_false(resumed)
      assert.matches("ssl_mode", tostring(err))
    end)

    it("rejects a wrong-typed ssl_mode", function()
      local resumed, err = open_result({ host = "127.0.0.1", ssl_mode = 3 })
      assert.is_false(resumed)
      assert.matches("ssl_mode", tostring(err))
    end)

    it("rejects a wrong-typed ssl_verify_server_cert", function()
      local resumed, err = open_result({ host = "127.0.0.1", ssl_verify_server_cert = "yes" })
      assert.is_false(resumed)
      assert.matches("ssl_verify_server_cert", tostring(err))
    end)

    it("family-gates ssl_verify_server_cert", function()
      -- Oracle 8.0: loud open-time error naming the key. MariaDB: the key
      -- passes validation and the (doomed, port 1) connect reports instead.
      local resumed, err, connect_err = open_result({
        host = "127.0.0.1", port = 1, connect_timeout = 1,
        ssl_verify_server_cert = true })
      if not resumed then
        assert.matches("ssl_verify_server_cert", tostring(err))
      else
        assert.not_matches("ssl_verify_server_cert", tostring(connect_err or ""))
      end
    end)

    it("family-gates ssl_mode", function()
      -- MariaDB: loud open-time error naming the key. Oracle: the value
      -- passes validation and the (doomed, port 1) connect reports instead.
      local resumed, err, connect_err = open_result({
        host = "127.0.0.1", port = 1, connect_timeout = 1,
        ssl_mode = "require" })
      if not resumed then
        assert.matches("ssl_mode", tostring(err))
      else
        assert.not_matches("ssl_mode", tostring(connect_err or ""))
      end
    end)
  end)

  describe("prepare validation", function()
    it("requires calling prepare from a coroutine", function()
      -- The coroutine guard fires before argument validation.
      assert.has_error(function()
        mysql.prepare(nil, "SELECT 1")
      end)
    end)

    it("rejects empty SQL", function()
      local co = coroutine.create(function()
        return mysql.prepare(nil, "")
      end)
      local resumed, err = coroutine.resume(co)
      assert.is_false(resumed)
      assert.matches("prepare", tostring(err))
    end)
  end)

  describe("checkout/release validation", function()
    it("checkout requires a coroutine", function()
      assert.has_error(function()
        mysql.checkout(nil)
      end)
    end)

    it("checkout rejects a non-pool handle", function()
      local co = coroutine.create(function()
        return mysql.checkout("not-a-pool")
      end)
      local resumed, r = coroutine.resume(co)
      assert.is_false(resumed)
      assert.is_truthy(r)
    end)

    it("release requires a coroutine", function()
      assert.has_error(function()
        mysql.release(nil)
      end)
    end)

    it("release rejects a non-conn handle", function()
      local co = coroutine.create(function()
        return mysql.release("not-a-conn")
      end)
      local resumed, r, e = coroutine.resume(co)
      assert.is_true(resumed)
      assert.is_nil(r)
      assert.is_truthy(e)
    end)
  end)

  describe("ping validation", function()
    it("requires calling ping from a coroutine", function()
      assert.has_error(function()
        mysql.ping(nil)
      end)
    end)

    it("rejects a non-connection handle", function()
      local co = coroutine.create(function()
        return mysql.ping("not-a-conn")
      end)
      local resumed, alive, e = coroutine.resume(co)
      assert.is_true(resumed)
      assert.is_false(alive)
      assert.is_truthy(e)
    end)
  end)
end)
