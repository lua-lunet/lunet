describe("JSON Module", function()
  if not package.searchpath("app.lib.json", package.path) then
    pending("app.lib.json not present in lunet core", function() end)
    return
  end

  local json = require("app.lib.json")

  it("encodes basic types", function()
    assert.are.equal("null", json.encode(nil))
    assert.are.equal("true", json.encode(true))
    assert.are.equal("false", json.encode(false))
    assert.are.equal("123", json.encode(123))
    assert.are.equal('"hello"', json.encode("hello"))
  end)

  it("encodes tables as objects or arrays", function()
    assert.are.equal("[]", json.encode({}))
    assert.are.equal("[1,2,3]", json.encode({1, 2, 3}))
    -- Objects might have random key order, so we check partials or decode back
    local encoded = json.encode({a = 1})
    assert.truthy(encoded == '{"a":1}')
  end)

  it("escapes strings correctly", function()
    assert.are.equal('"\\""', json.encode('"'))
    assert.are.equal('"\\\\"', json.encode('\\'))
    assert.are.equal('"\\n"', json.encode('\n'))
  end)

  it("decodes basic types", function()
    assert.are.equal(true, json.decode("true"))
    assert.are.equal(false, json.decode("false"))
    assert.are.equal(nil, json.decode("null"))
    assert.are.equal(123, json.decode("123"))
    assert.are.equal("hello", json.decode('"hello"'))
  end)

  it("decodes arrays and objects", function()
    local arr = json.decode("[1, 2, 3]")
    assert.are.same({1, 2, 3}, arr)

    local obj = json.decode('{"a": 1}')
    assert.are.same({a = 1}, obj)
  end)

  it("handles null bytes in strings (The Crash Test)", function()
    -- This was causing the regex error
    local s = "\0"
    local encoded = json.encode(s)
    -- Expect \u0000
    assert.are.equal('"\\u0000"', encoded)
  end)
  
  it("handles control characters", function()
    local s = "\001\031"
    local encoded = json.encode(s)
    assert.are.equal('"\\u0001\\u001f"', encoded)
  end)
end)
