describe("HTTP Module", function()
  if not package.searchpath("app.lib.http", package.path) then
    pending("app.lib.http not present in lunet core", function() end)
    return
  end

  local http = require("app.lib.http")

  describe("parse_query_string", function()
    it("parses empty string", function()
      assert.are.same({}, http.parse_query_string(""))
      assert.are.same({}, http.parse_query_string(nil))
    end)

    it("parses single param", function()
      assert.are.same({foo = "bar"}, http.parse_query_string("foo=bar"))
    end)

    it("parses multiple params", function()
      local result = http.parse_query_string("limit=10&offset=20&tag=lua")
      assert.are.same({limit = "10", offset = "20", tag = "lua"}, result)
    end)

    it("decodes URL encoded values", function()
      local result = http.parse_query_string("name=hello%20world")
      assert.are.same({name = "hello world"}, result)
    end)

    it("handles plus as space", function()
      local result = http.parse_query_string("q=hello+world")
      assert.are.same({q = "hello world"}, result)
    end)
  end)

  describe("parse_request", function()
    it("parses simple GET request", function()
      local raw = "GET /api/articles HTTP/1.1\r\nHost: localhost\r\n\r\n"
      local req = http.parse_request(raw)
      assert.are.equal("GET", req.method)
      assert.are.equal("/api/articles", req.path)
      assert.are.equal("localhost", req.headers["host"])
    end)

    it("parses GET with query string", function()
      local raw = "GET /api/articles?limit=10&offset=5 HTTP/1.1\r\nHost: localhost\r\n\r\n"
      local req = http.parse_request(raw)
      assert.are.equal("/api/articles", req.path)
      assert.are.equal("limit=10&offset=5", req.query_string)
      assert.are.equal("10", req.query_params.limit)
      assert.are.equal("5", req.query_params.offset)
    end)

    it("parses POST with body", function()
      local body = '{"user":{"email":"test@example.com"}}'
      local raw = "POST /api/users HTTP/1.1\r\n" ..
                  "Host: localhost\r\n" ..
                  "Content-Type: application/json\r\n" ..
                  "Content-Length: " .. #body .. "\r\n" ..
                  "\r\n" .. body
      local req = http.parse_request(raw)
      assert.are.equal("POST", req.method)
      assert.are.equal("/api/users", req.path)
      assert.are.equal(body, req.body)
    end)

    it("returns nil for incomplete request", function()
      local raw = "GET /api/articles HTTP/1.1\r\nHost: localhost"
      local req, err = http.parse_request(raw)
      assert.is_nil(req)
      assert.are.equal("incomplete request", err)
    end)
  end)

  describe("response", function()
    it("builds basic response", function()
      local resp = http.response(200, {}, "OK")
      assert.truthy(resp:find("HTTP/1.1 200 OK"))
      assert.truthy(resp:find("Content%-Length: 2"))
    end)

    it("includes custom headers", function()
      local resp = http.response(201, {["X-Custom"] = "value"}, "Created")
      assert.truthy(resp:find("X%-Custom: value"))
    end)
  end)

  describe("json_response", function()
    it("encodes data as JSON", function()
      local resp = http.json_response(200, {message = "hello"})
      assert.truthy(resp:find("Content%-Type: application/json"))
      assert.truthy(resp:find('"message"'))
      assert.truthy(resp:find('"hello"'))
    end)
  end)

  describe("error_response", function()
    it("formats string error", function()
      local resp = http.error_response(400, "Invalid input")
      assert.truthy(resp:find("400 Bad Request"))
      assert.truthy(resp:find("Invalid input"))
    end)

    it("formats table of errors", function()
      local resp = http.error_response(422, {email = {"is required"}})
      assert.truthy(resp:find("email is required"))
    end)

    it("formats array of errors", function()
      local resp = http.error_response(400, {"error1", "error2"})
      assert.truthy(resp:find("error1"))
      assert.truthy(resp:find("error2"))
    end)
  end)
end)
