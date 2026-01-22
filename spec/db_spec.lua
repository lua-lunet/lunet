describe("DB Module (pure functions)", function()
  local db

  setup(function()
    package.loaded["lunet.db"] = {
      open = function() return {} end,
      close = function() end,
      query = function() return {} end,
      exec = function() return {} end,
      escape = function(s)
        return s:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n"):gsub("\r", "\\r")
      end,
    }
    db = require("app.lib.db")
  end)

  teardown(function()
    package.loaded["lunet.db"] = nil
    package.loaded["app.lib.db"] = nil
  end)

  describe("escape", function()
    it("escapes nil as NULL", function()
      assert.are.equal("NULL", db.escape(nil))
    end)

    it("escapes numbers", function()
      assert.are.equal("123", db.escape(123))
      assert.are.equal("3.14", db.escape(3.14))
    end)

    it("escapes booleans", function()
      assert.are.equal("1", db.escape(true))
      assert.are.equal("0", db.escape(false))
    end)

    it("escapes strings with quotes", function()
      assert.are.equal("'hello'", db.escape("hello"))
      assert.are.equal("'\\'test\\''", db.escape("'test'"))
    end)

    it("escapes backslashes", function()
      assert.are.equal("'path\\\\to\\\\file'", db.escape("path\\to\\file"))
    end)

    it("escapes newlines", function()
      assert.are.equal("'line1\\nline2'", db.escape("line1\nline2"))
    end)

    it("escapes carriage returns", function()
      assert.are.equal("'line1\\rline2'", db.escape("line1\rline2"))
    end)
  end)

  describe("interpolate", function()
    it("replaces single placeholder", function()
      local sql = db.interpolate("SELECT * FROM users WHERE id = ?", 42)
      assert.are.equal("SELECT * FROM users WHERE id = 42", sql)
    end)

    it("replaces multiple placeholders", function()
      local sql = db.interpolate("SELECT * FROM users WHERE name = ? AND age > ?", "John", 18)
      assert.are.equal("SELECT * FROM users WHERE name = 'John' AND age > 18", sql)
    end)

    it("handles NULL values", function()
      local sql = db.interpolate("INSERT INTO users (name, bio) VALUES (?, ?)", "Test", nil)
      assert.are.equal("INSERT INTO users (name, bio) VALUES ('Test', NULL)", sql)
    end)

    it("escapes dangerous characters for SQL injection prevention", function()
      local sql = db.interpolate("SELECT * FROM users WHERE name = ?", "'; DROP TABLE users; --")
      assert.truthy(sql:find("\\'"))
      assert.truthy(sql:find("DROP TABLE"))
    end)
  end)
end)
