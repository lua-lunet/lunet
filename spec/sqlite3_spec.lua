describe("sqlite3 module #native", function()
  local ok, db = pcall(require, "lunet.sqlite3")
  if not ok then
    pending("lunet.sqlite3 not built (xmake build lunet-sqlite3)", function() end)
    return
  end

  it("exports the driver surface", function()
    assert.are.equal("table", type(db))
    for _, fn in ipairs({ "open", "connect", "close", "query_ro", "query", "exec",
                          "query_params", "exec_params", "prepare" }) do
      assert.are.equal("function", type(db[fn]))
    end
  end)

  -- open-style guards are raised before any yield or queue, so they
  -- surface through a plain coroutine.resume.
  local function open_error(params)
    local co = coroutine.create(function()
      return db.open(params)
    end)
    local resumed, err = coroutine.resume(co)
    return resumed, err
  end

  local function connect_error(path, opts)
    local co = coroutine.create(function()
      return db.connect(path, opts)
    end)
    local resumed, err = coroutine.resume(co)
    return resumed, err
  end

  it("requires calling open inside a coroutine", function()
    assert.has_error(function()
      db.open({ path = "sqlite3_spec_should_not_exist.db" })
    end)
  end)

  it("requires a params table to open", function()
    local resumed, err = open_error("not-a-table")
    assert.is_false(resumed)
    assert.is_truthy(err)
  end)

  it("rejects an unknown option name loudly", function()
    local resumed, err = open_error({ path = "x.db", pool_size = 4 })
    assert.is_false(resumed)
    assert.matches("pool_size", tostring(err))
  end)

  it("rejects an invalid create value", function()
    local resumed, err = open_error({ path = "x.db", create = "MAGIC" })
    assert.is_false(resumed)
    assert.matches("create", tostring(err))
  end)

  it("rejects an invalid synchronous value", function()
    local resumed, err = open_error({ path = "x.db", synchronous = "TURBO" })
    assert.is_false(resumed)
    assert.matches("synchronous", tostring(err))
  end)

  it("rejects a negative busy_timeout", function()
    local resumed, err = open_error({ path = "x.db", busy_timeout = -1 })
    assert.is_false(resumed)
    assert.matches("busy_timeout", tostring(err))
  end)

  it("rejects an invalid mutex value", function()
    local resumed, err = open_error({ path = "x.db", mutex = "YESSIR" })
    assert.is_false(resumed)
    assert.matches("mutex", tostring(err))
  end)

  it("connect rejects an unknown option too", function()
    local resumed, err = connect_error("x.db", { crash_on_error = true })
    assert.is_false(resumed)
    assert.matches("crash_on_error", tostring(err))
  end)

  describe("prepare validation", function()
    it("requires calling prepare from a coroutine", function()
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
