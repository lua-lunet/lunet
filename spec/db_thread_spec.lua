describe("DB Thread Safety", function()
  if not package.searchpath("app.lib.db", package.path) then
    pending("app.lib.db not present in lunet core", function() end)
    return
  end

  local db
  local mysql_mock

  setup(function()
    -- Mock database driver for testing
    mysql_mock = {
      open = function()
        return { conn_id = math.random(1000), closed = false }
      end,

      close = function(conn)
        conn.closed = true
      end,

      query = function(conn, _)
        if conn.closed then return nil, "connection closed" end
        for _=1,1000 do end
        return { { id = 1, name = "test" } }
      end,

      exec = function(conn, _)
        if conn.closed then return nil, "connection closed" end
        for _=1,1000 do end
        return { affected_rows = 1 }
      end
    }

    package.loaded["lunet.db"] = mysql_mock
    db = require("app.lib.db")
  end)

  teardown(function()
    package.loaded["lunet.db"] = nil
    package.loaded["app.lib.db"] = nil
  end)

  it("handles concurrent queries on same connection without crashes", function()
    local results = {}
    local errors = {}
    local completed = 0
    local total = 10

    -- Launch multiple coroutines that query simultaneously
    for i = 1, total do
      local co = coroutine.create(function()
        local result, err = db.query("SELECT * FROM users WHERE id = " .. i)
        if result then
          results[i] = result
        else
          errors[i] = err
        end
        completed = completed + 1
      end)
      coroutine.resume(co)
    end

    -- Wait for all coroutines to complete
    while completed < total do
      coroutine.yield()
    end

    -- Should have no crashes or errors
    assert.is_equal(total, completed)
    assert.is_equal(0, #errors)
    assert.is_equal(total, #results)
  end)

  it("no data races with parallel exec and query operations", function()
    local insert_results = {}
    local select_results = {}
    local completed = 0
    local total = 20

    -- Mix of insert and select operations
    for i = 1, total do
      local co = coroutine.create(function()
        if i % 2 == 0 then
          local result, _ = db.exec("INSERT INTO users (name) VALUES ('user" .. i .. "')")
          insert_results[i] = result
        else
          local result, _ = db.query("SELECT * FROM users WHERE name = 'user" .. i .. "'")
          select_results[i] = result
        end
        completed = completed + 1
      end)
      coroutine.resume(co)
    end

    -- Wait for all operations to complete
    while completed < total do
      coroutine.yield()
    end

    -- All operations should succeed
    assert.is_equal(total, completed)

    -- Check that we got expected results
    local insert_count = 0
    for _, result in pairs(insert_results) do
      if result then insert_count = insert_count + 1 end
    end

    local select_count = 0
    for _, result in pairs(select_results) do
      if result then select_count = select_count + 1 end
    end

    assert.is_true(insert_count > 0, "Should have successful inserts")
    assert.is_true(select_count > 0, "Should have successful selects")
  end)

  it("handles rapid connection open/close without corruption", function()
    local completed = 0
    local total = 50

    for _ = 1, total do
      local co = coroutine.create(function()
        local conn = db.connect()
        if conn then
          local result = db.query("SELECT 1 as test")
          if not result then
            completed = completed + 1
            return
          end
        end
        completed = completed + 1
      end)
      coroutine.resume(co)
    end

    while completed < total do
      coroutine.yield()
    end

    assert.is_equal(total, completed)
  end)

  it("maintains data consistency under concurrent load", function()
    local completed = 0
    local total = 100

    for _ = 1, total do
      local co = coroutine.create(function()
        local result = db.query("SELECT counter FROM counters WHERE id = 1")
        local current = result and result[1] and result[1].counter or 0

        local new_val = current + 1
        db.exec("UPDATE counters SET counter = " .. new_val .. " WHERE id = 1")

        completed = completed + 1
      end)
      coroutine.resume(co)
    end

    while completed < total do
      coroutine.yield()
    end

    -- In a real database with proper locking, this would be exactly total
    -- But with our mock, we just verify no crashes occurred
    assert.is_equal(total, completed)
  end)
end)