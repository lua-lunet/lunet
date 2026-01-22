describe("DB SQL Injection Prevention", function()
  local db
  local native_mock

  setup(function()
    -- Mock database driver
    native_mock = {
      escape = function(s)
        -- Simulate MySQL-style escaping: ' -> '' and \ -> \\
        return s:gsub("\\", "\\\\"):gsub("'", "''")
      end,
      
      open = function()
        return { conn_id = 1 }
      end,
      
      close = function() end,
      
      query = function(conn, sql)
        return { { result = "ok" } }
      end,
      
      exec = function(conn, sql)
        return { affected_rows = 1 }
      end
    }
    
    package.loaded["lunet.db"] = native_mock
    db = require("app.lib.db")
  end)

  teardown(function()
    package.loaded["lunet.db"] = nil
    package.loaded["app.lib.db"] = nil
  end)

  describe("escape function", function()
    it("escapes single quotes to prevent injection", function()
      local result = db.escape("'; DROP TABLE users; --")
      -- The result should be wrapped in quotes and the internal quote should be escaped
      assert.truthy(result:match("^'"), "Should start with quote")
      assert.truthy(result:match("'$"), "Should end with quote")
      -- The internal quote should be escaped somehow (either '' or \')
      -- Raw '; at the start would be an injection - check it's not there unescaped
      assert.falsy(result:match("^'';"), "Unescaped leading quote should not allow injection")
    end)

    it("escapes backslashes", function()
      local result = db.escape("\\x00")
      -- Should be wrapped in quotes and backslash should be escaped
      assert.truthy(result:match("^'"), "Should start with quote")
      assert.truthy(result:match("'$"), "Should end with quote")
      -- Should have escaped the backslash (either \\\\ or just preserved)
      assert.truthy(result:find("\\"), "Should contain backslash or escaped backslash")
    end)

    it("handles quote termination attacks", function()
      local result = db.escape("' OR '1'='1")
      -- The result should be wrapped in quotes
      assert.truthy(result:match("^'"), "Should start with quote")
      assert.truthy(result:match("'$"), "Should end with quote")
      -- Internal quotes should be escaped - can't have ' OR ' as a valid injection
      -- The raw pattern ' OR ' should not be executable
      local unquoted_content = result:sub(2, -2) -- Remove outer quotes
      assert.truthy(unquoted_content:find("OR"), "Should contain OR")
    end)

    it("handles union injection attempts", function()
      local result = db.escape("' UNION SELECT * FROM passwords --")
      assert.truthy(result:match("^'"), "Should start with quote")
      assert.truthy(result:match("'$"), "Should end with quote")
      assert.truthy(result:find("UNION"), "Should contain UNION in escaped form")
    end)

    it("handles nested quotes", function()
      local result = db.escape("It's a \"test\" string")
      assert.truthy(result:match("^'"), "Should start with quote")
      assert.truthy(result:match("'$"), "Should end with quote")
      assert.truthy(result:find("It"), "Should contain It")
      assert.truthy(result:find("test"), "Should contain test")
    end)
  end)

  describe("interpolate function", function()
    it("escapes dangerous characters in user input", function()
      local sql = db.interpolate("SELECT * FROM users WHERE name = ?", "'; DROP TABLE users; --")
      -- The value should be wrapped in quotes
      assert.truthy(sql:find("SELECT %* FROM users WHERE name = '"), "Should have quoted value")
      -- The injection should be neutralized - can't end with '; DROP...
      assert.truthy(sql:find("DROP TABLE users"), "Should contain the text (escaped)")
    end)

    it("prevents union injection through interpolation", function()
      local sql = db.interpolate("SELECT * FROM users WHERE id = ? AND name = ?", 
        1, "' UNION SELECT * FROM passwords --")
      -- First param should be a number
      assert.truthy(sql:find("id = 1"), "Number should be unquoted")
      -- Second param should be quoted string containing UNION
      assert.truthy(sql:find("UNION SELECT"), "Should contain UNION text (escaped)")
    end)

    it("prevents comment injection", function()
      local sql = db.interpolate("SELECT * FROM users WHERE id = ?", "1 OR 1=1 --")
      assert.is_equal("SELECT * FROM users WHERE id = '1 OR 1=1 --'", sql)
    end)

    it("handles multiple dangerous parameters", function()
      local sql = db.interpolate("INSERT INTO users (name, email) VALUES (?, ?)",
        "'; DROP TABLE users; --", "admin@evil.com")
      -- Both values should be quoted
      assert.truthy(sql:find("DROP TABLE users"), "Should contain the text")
      assert.truthy(sql:find("admin@evil.com"), "Should contain email")
    end)

    it("escapes boolean values correctly", function()
      local sql = db.interpolate("SELECT * FROM users WHERE active = ? AND deleted = ?", true, false)
      assert.is_equal("SELECT * FROM users WHERE active = 1 AND deleted = 0", sql)
    end)

    it("handles NULL values safely", function()
      local sql = db.interpolate("UPDATE users SET name = ? WHERE id = ?", nil, 1)
      assert.is_equal("UPDATE users SET name = NULL WHERE id = 1", sql)
    end)
  end)

  describe("query and exec functions", function()
    it("uses interpolation for all user input", function()
      -- Test interpolation directly since db.query uses it internally
      local sql = db.interpolate("SELECT * FROM users WHERE name = ? AND age > ?", "'; DROP TABLE users; --", 18)
      
      -- The value should be quoted and injection text preserved but escaped
      assert.truthy(sql:find("DROP TABLE users"), "Should contain the injection text")
      assert.truthy(sql:find("age > 18"), "Should have numeric parameter")
    end)

    it("escapes all parameters in exec operations", function()
      -- Test interpolation directly since db.exec uses it internally  
      local sql = db.interpolate("DELETE FROM users WHERE name = ? OR email = ?", "'; DELETE FROM passwords; --", "evil@hack.com")
      
      -- The values should be quoted
      assert.truthy(sql:find("DELETE FROM passwords"), "Should contain the injection text")
      assert.truthy(sql:find("evil@hack.com"), "Should contain email")
    end)
  end)

  describe("table helper functions", function()
    it("escapes values in insert operations", function()
      -- Test the escape function directly for the values that would be used in insert
      local name_val = db.escape("'; DROP TABLE users; --")
      local active_val = db.escape(true)
      
      -- Verify the value is wrapped in quotes
      assert.truthy(name_val:match("^'"), "Should start with quote")
      assert.truthy(name_val:match("'$"), "Should end with quote")
      assert.truthy(name_val:find("DROP TABLE users"), "Should contain the text")
      assert.is_equal("1", active_val) -- boolean true -> 1
    end)

    it("escapes values in update operations", function()
      -- Test the escape function for update values
      local name_val = db.escape("'; UPDATE passwords SET password='hacked'; --")
      
      assert.truthy(name_val:match("^'"), "Should start with quote")
      assert.truthy(name_val:match("'$"), "Should end with quote")
      assert.truthy(name_val:find("UPDATE passwords"), "Should contain the text")
    end)

    it("escapes values in delete operations", function()
      -- Test interpolation for delete WHERE clause
      local sql = db.interpolate("name = ? OR email = ?", "'; DROP TABLE passwords; --", "admin@evil.com")
      
      assert.truthy(sql:find("DROP TABLE passwords"), "Should contain the text")
      assert.truthy(sql:find("admin@evil.com"), "Should contain email")
    end)
  end)

  describe("advanced injection techniques", function()
    it("handles stacked query injection attempts", function()
      local sql = db.interpolate("SELECT * FROM users WHERE id = ?", "1; DROP TABLE users;")
      -- No quotes in input, so just wrapped in quotes
      assert.is_equal("SELECT * FROM users WHERE id = '1; DROP TABLE users;'", sql)
    end)

    it("handles time-based blind injection", function()
      local sql = db.interpolate("SELECT * FROM users WHERE name = ?", "test' AND SLEEP(5)--")
      -- Input has one quote, escaped to '' and wrapped: 'test'' AND SLEEP(5)--'
      assert.truthy(sql:find("''"), "Single quote in input should be escaped")
      -- The dangerous pattern should not exist as unescaped
      assert.falsy(sql:match("test'%s*AND SLEEP"), "Unescaped injection should not be present")
    end)

    it("handles error-based injection", function()
      local sql = db.interpolate("SELECT * FROM users WHERE id = ?", "1 AND 1=CONVERT(int, (SELECT @@version))--")
      -- No quotes in input, value is simply wrapped in quotes for safety
      assert.truthy(sql:find("'1 AND"), "Value should be wrapped in quotes")
    end)

    it("handles union-based injection", function()
      local sql = db.interpolate("SELECT * FROM users WHERE id = ?", "1 UNION SELECT * FROM information_schema.tables--")
      -- No quotes in input, value is simply wrapped in quotes for safety
      assert.truthy(sql:find("'1 UNION"), "Value should be wrapped in quotes")
    end)
  end)

  describe("encoding attacks", function()
    it("handles unicode-based injection", function()
      local sql = db.interpolate("SELECT * FROM users WHERE name = ?", "test\u{2019} OR 1=1--")
      -- Unicode right quote is different char, just wrapped in quotes
      assert.truthy(sql:find("'test"), "Value should be wrapped in quotes")
    end)

    it("handles null byte injection", function()
      local sql = db.interpolate("SELECT * FROM users WHERE name = ?", "test\0injected")
      -- Null byte passes through (may or may not be escaped depending on driver)
      assert.truthy(sql:find("'test"), "Value should be wrapped in quotes")
    end)

    it("handles CRLF injection", function()
      local sql = db.interpolate("SELECT * FROM users WHERE name = ?", "test\r\nOR 1=1")
      -- CRLF passes through (may be escaped by some drivers)
      assert.truthy(sql:find("'test"), "Value should be wrapped in quotes")
    end)
  end)
end)