describe("DB Module (param dispatch)", function()
  local db

  setup(function()
    local calls = {
      query_raw = 0,
      exec_raw = 0,
      query_params = 0,
      exec_params = 0,
    }

    package.loaded["lunet.db"] = {
      open = function() return {} end,
      close = function() end,
      escape = function(s) return s end,

      query = function(conn, sql)
        calls.query_raw = calls.query_raw + 1
        return { { sql = sql } }
      end,
      exec = function(conn, sql)
        calls.exec_raw = calls.exec_raw + 1
        return { affected_rows = 1, sql = sql }
      end,

      query_params = function(conn, sql, ...)
        calls.query_params = calls.query_params + 1
        return { { sql = sql, params = { ... } } }
      end,
      exec_params = function(conn, sql, ...)
        calls.exec_params = calls.exec_params + 1
        return { affected_rows = 1, sql = sql, params = { ... } }
      end,
    }

    db = require("app.lib.db")
    db._calls = calls
  end)

  teardown(function()
    package.loaded["lunet.db"] = nil
    package.loaded["app.lib.db"] = nil
  end)

  it("uses query_params when args are provided", function()
    local rows = assert(db.query("SELECT ? AS v", "x"))
    assert.are.equal(1, db._calls.query_params)
    assert.are.equal(0, db._calls.query_raw)
    assert.are.same({ "x" }, rows[1].params)
  end)

  it("uses exec_params when args are provided", function()
    local res = assert(db.exec("UPDATE t SET v=?", 123))
    assert.are.equal(1, db._calls.exec_params)
    assert.are.equal(0, db._calls.exec_raw)
    assert.are.same({ 123 }, res.params)
  end)

  it("uses query_raw when no args are provided", function()
    local rows = assert(db.query("SELECT 1"))
    assert.are.equal(1, db._calls.query_raw)
    assert.are.equal("SELECT 1", rows[1].sql)
  end)

  it("uses exec_raw when no args are provided", function()
    local res = assert(db.exec("DELETE FROM t"))
    assert.are.equal(1, db._calls.exec_raw)
    assert.are.equal("DELETE FROM t", res.sql)
  end)
end)
