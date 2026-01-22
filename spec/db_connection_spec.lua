describe("DB Connection Management", function()
  local db
  local mysql_mock

  setup(function()
    -- Create mock that tracks connection lifecycle
    mysql_mock = {
      open_calls = {},
      close_calls = {},
      query_calls = {},
      exec_calls = {},
      escape_calls = {},
      
      reset = function()
        mysql_mock.open_calls = {}
        mysql_mock.close_calls = {}
        mysql_mock.query_calls = {}
        mysql_mock.exec_calls = {}
        mysql_mock.escape_calls = {}
      end,
      
      open = function(cfg)
        local conn = {
          conn_id = #mysql_mock.open_calls + 1,
          cfg = cfg,
          created_at = os.time(),
          closed = false
        }
        table.insert(mysql_mock.open_calls, conn)
        return conn
      end,
      
      close = function(conn)
        conn.closed = true
        table.insert(mysql_mock.close_calls, conn)
      end,
      
      query = function(conn, sql)
        table.insert(mysql_mock.query_calls, {conn = conn, sql = sql})
        if conn.closed then return nil, "connection closed" end
        return { { id = 1, name = "test" } }
      end,
      
      exec = function(conn, sql)
        table.insert(mysql_mock.exec_calls, {conn = conn, sql = sql})
        if conn.closed then return nil, "connection closed" end
        return { affected_rows = 1 }
      end,
      
      escape = function(s)
        table.insert(mysql_mock.escape_calls, s)
        return s:gsub("'", "''")
      end
    }
    
    package.loaded["lunet.db"] = mysql_mock
    db = require("app.lib.db")
  end)

  teardown(function()
    package.loaded["lunet.db"] = nil
    package.loaded["app.lib.db"] = nil
  end)

  before_each(function()
    mysql_mock.reset()
  end)

  it("opens new connection for each query", function()
    -- First query
    local result1 = db.query("SELECT * FROM users")
    
    -- Second query
    local result2 = db.query("SELECT * FROM posts")
    
    -- Should have opened two separate connections
    assert.is_equal(2, #mysql_mock.open_calls)
    assert.is_not_equal(mysql_mock.open_calls[1], mysql_mock.open_calls[2])
    assert.is_equal(1, mysql_mock.open_calls[1].conn_id)
    assert.is_equal(2, mysql_mock.open_calls[2].conn_id)
  end)

  it("opens new connection for each exec", function()
    db.exec("INSERT INTO users (name) VALUES ('test')")
    db.exec("UPDATE users SET name = 'updated'")
    
    assert.is_equal(2, #mysql_mock.open_calls)
    assert.is_not_equal(mysql_mock.open_calls[1], mysql_mock.open_calls[2])
  end)

  it("closes connection after each query", function()
    db.query("SELECT * FROM users")
    
    assert.is_equal(1, #mysql_mock.open_calls)
    assert.is_equal(1, #mysql_mock.close_calls)
    assert.is_equal(mysql_mock.open_calls[1], mysql_mock.close_calls[1])
    assert.is_true(mysql_mock.close_calls[1].closed)
  end)

  it("closes connection after each exec", function()
    db.exec("INSERT INTO users (name) VALUES ('test')")
    
    assert.is_equal(1, #mysql_mock.open_calls)
    assert.is_equal(1, #mysql_mock.close_calls)
    assert.is_equal(mysql_mock.open_calls[1], mysql_mock.close_calls[1])
  end)

  it("does not reuse connections across different operations", function()
    -- Query then exec
    db.query("SELECT * FROM users")
    db.exec("INSERT INTO users (name) VALUES ('test')")
    
    assert.is_equal(2, #mysql_mock.open_calls)
    assert.is_equal(2, #mysql_mock.close_calls)
    
    -- All connections should be different
    for i = 1, #mysql_mock.open_calls do
      for j = i + 1, #mysql_mock.open_calls do
        assert.is_not_equal(mysql_mock.open_calls[i], mysql_mock.open_calls[j])
      end
    end
  end)

  it("closes connection even on query error", function()
    -- Store original and override db.query_raw directly (since db caches native.query)
    local original_query_raw = db.query_raw
    db.query_raw = function(conn, sql)
      table.insert(mysql_mock.query_calls, {conn = conn, sql = sql})
      return nil, "query failed"
    end
    
    local result, err = db.query("SELECT * FROM invalid_table")
    
    assert.is_nil(result)
    assert.is_equal("query failed", err)
    assert.is_equal(1, #mysql_mock.open_calls)
    assert.is_equal(1, #mysql_mock.close_calls) -- Should still close
    
    db.query_raw = original_query_raw
  end)

  it("closes connection even on exec error", function()
    -- Store original and override db.exec_raw directly (since db caches native.exec)
    local original_exec_raw = db.exec_raw
    db.exec_raw = function(conn, sql)
      table.insert(mysql_mock.exec_calls, {conn = conn, sql = sql})
      return nil, "exec failed"
    end
    
    local result, err = db.exec("INSERT INTO invalid_table VALUES (1)")
    
    assert.is_nil(result)
    assert.is_equal("exec failed", err)
    assert.is_equal(1, #mysql_mock.open_calls)
    assert.is_equal(1, #mysql_mock.close_calls) -- Should still close
    
    db.exec_raw = original_exec_raw
  end)

  it("does not maintain connection pool or cache", function()
    -- Perform many operations
    for i = 1, 10 do
      db.query("SELECT * FROM users WHERE id = " .. i)
    end
    
    -- Should have opened 10 separate connections
    assert.is_equal(10, #mysql_mock.open_calls)
    assert.is_equal(10, #mysql_mock.close_calls)
    
    -- No connection should be reused
    local unique_conns = {}
    for _, conn in ipairs(mysql_mock.open_calls) do
      unique_conns[conn.conn_id] = true
    end
    -- Count hash table entries (# operator doesn't work on hash tables)
    local unique_count = 0
    for _ in pairs(unique_conns) do unique_count = unique_count + 1 end
    assert.is_equal(10, unique_count)
  end)

  it("handles rapid connection cycling without leaks", function()
    -- Rapid open/close cycles
    for i = 1, 20 do
      local conn = db.connect()
      assert.is_not_nil(conn)
      db.close(conn)
    end
    
    -- All connections should be tracked and closed
    assert.is_equal(20, #mysql_mock.open_calls)
    assert.is_equal(20, #mysql_mock.close_calls)
    
    -- Verify all are closed
    for _, conn in ipairs(mysql_mock.close_calls) do
      assert.is_true(conn.closed)
    end
  end)

  it("connection objects are independent", function()
    local conn1 = db.connect()
    local conn2 = db.connect()
    
    -- Different objects
    assert.is_not_equal(conn1, conn2)
    assert.is_not_equal(conn1.conn_id, conn2.conn_id)
    
    -- Operations on one don't affect the other (use query_raw which takes connection)
    db.query_raw(conn1, "SELECT 1")
    db.query_raw(conn2, "SELECT 2")
    
    assert.is_equal(2, #mysql_mock.query_calls)
    assert.is_equal(conn1, mysql_mock.query_calls[1].conn)
    assert.is_equal(conn2, mysql_mock.query_calls[2].conn)
    
    -- Clean up connections
    db.close(conn1)
    db.close(conn2)
  end)
end)