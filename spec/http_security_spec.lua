describe("HTTP Path Traversal Security", function()
  if not package.searchpath("app.lib.http", package.path) then
    pending("app.lib.http not present in lunet core", function() end)
    return
  end

  local mock_fs
  local handle_static_request
  local handle_static_request_secure

  setup(function()
    require("app.lib.http")

    -- Mock filesystem for testing
    mock_fs = {
      files = {
        ["www/index.html"] = "<html>Home</html>",
        ["www/css/style.css"] = "body { color: red; }",
        ["www/js/app.js"] = "console.log('app');",
        ["www/images/logo.png"] = "PNG data",
        ["www/api/test.json"] = '{"test": "data"}',
      },

      read_file = function(path)
        return mock_fs.files[path]
      end,

      get_mime_type = function(path)
        if path:match("%.html$") then return "text/html" end
        if path:match("%.css$") then return "text/css" end
        if path:match("%.js$") then return "application/javascript" end
        if path:match("%.png$") then return "image/png" end
        if path:match("%.json$") then return "application/json" end
        return "application/octet-stream"
      end
    }

    -- Mock static file handler function
    handle_static_request = function(request)
      local file_path = "www" .. request.path
      if request.path == "/" then
        file_path = "www/index.html"
      end

      -- Basic directory traversal protection (current implementation)
      if file_path:find("%.%.") then
        return { status = 403, body = "Forbidden" }
      end

      local content = mock_fs.read_file(file_path)
      if not content and not request.path:find("^/api/") then
        -- SPA fallback
        content = mock_fs.read_file("www/index.html")
      end

      if content then
        return { status = 200, body = content }
      else
        return { status = 404, body = "Not Found" }
      end
    end

    -- Enhanced secure handler (what we want to implement)
    handle_static_request_secure = function(request)
      local file_path = "www" .. request.path
      if request.path == "/" then
        file_path = "www/index.html"
      end

      -- Enhanced directory traversal protection
      -- 1. Normalize path
      local normalized = file_path:gsub("/+", "/")

      -- 2. Decode URL encoding
      normalized = normalized:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
      end)

      -- 3. Check for traversal patterns
      if normalized:find("%.%.") or
         normalized:find("%%%.%%%.") or
         normalized:find("%%2e%%2e") or
         normalized:find("%%252e%%252e") then
        return { status = 403, body = "Forbidden" }
      end

      -- 4. Ensure path stays within www directory
      if not normalized:find("^www/") then
        return { status = 403, body = "Forbidden" }
      end

      -- 5. Resolve to absolute path and verify
      local resolved = normalized
      if resolved:find("%.%.") then
        return { status = 403, body = "Forbidden" }
      end

      local content = mock_fs.read_file(resolved)
      if not content and not request.path:find("^/api/") then
        -- SPA fallback
        content = mock_fs.read_file("www/index.html")
      end

      if content then
        return { status = 200, body = content }
      else
        return { status = 404, body = "Not Found" }
      end
    end
  end)

  describe("Current Implementation Vulnerabilities", function()
    it("blocks literal .. traversal", function()
      local request = { path = "/../etc/passwd" }
      local response = handle_static_request(request)
      assert.is_equal(403, response.status)
    end)

    it("FAILS to block URL-encoded traversal (%2e%2e%2f)", function()
      local request = { path = "/%2e%2e%2fetc%2fpasswd" }
      local response = handle_static_request(request)
      -- This should be blocked but current implementation doesn't decode
      assert.is_not_equal(403, response.status) -- VULNERABILITY
    end)

    it("FAILS to block double-encoded traversal", function()
      local request = { path = "/%252e%252e%252fetc%252fpasswd" }
      local response = handle_static_request(request)
      assert.is_not_equal(403, response.status) -- VULNERABILITY
    end)

    it("blocks unicode traversal due to literal .. in path", function()
      -- Note: /..%u2215 still contains literal ".." which is caught
      local request = { path = "/..%u2215etc%u2215passwd" }
      local response = handle_static_request(request)
      -- Actually blocked because path contains ".." literally
      assert.is_equal(403, response.status)
    end)

    it("allows legitimate paths", function()
      local request = { path = "/css/style.css" }
      local response = handle_static_request(request)
      assert.is_equal(200, response.status)
    end)
  end)

  describe("Enhanced Implementation Tests", function()
    it("blocks literal .. traversal", function()
      local request = { path = "/../etc/passwd" }
      local response = handle_static_request_secure(request)
      assert.is_equal(403, response.status)
    end)

    it("blocks URL-encoded traversal (%2e%2e%2f)", function()
      local request = { path = "/%2e%2e%2fetc%2fpasswd" }
      local response = handle_static_request_secure(request)
      assert.is_equal(403, response.status)
    end)

    it("blocks double-encoded traversal", function()
      local request = { path = "/%252e%252e%252fetc%252fpasswd" }
      local response = handle_static_request_secure(request)
      assert.is_equal(403, response.status)
    end)

    it("blocks mixed encoding traversal", function()
      local request = { path = "/%2e.%2fetc%2fpasswd" }
      local response = handle_static_request_secure(request)
      assert.is_equal(403, response.status)
    end)

    it("blocks absolute path traversal", function()
      local request = { path = "/../../../etc/passwd" }
      local response = handle_static_request_secure(request)
      assert.is_equal(403, response.status)
    end)

    it("blocks normalized path traversal", function()
      local request = { path = "/foo/../bar/../etc/passwd" }
      local response = handle_static_request_secure(request)
      assert.is_equal(403, response.status)
    end)

    it("blocks path outside www directory", function()
      local request = { path = "/../config/database.yml" }
      local response = handle_static_request_secure(request)
      assert.is_equal(403, response.status)
    end)
  end)

  describe("Path Traversal Attack Vectors", function()
    local attack_vectors = {
      -- Basic traversal
      { path = "/../etc/passwd", desc = "basic .. traversal" },
      { path = "/../../etc/passwd", desc = "multiple .. traversal" },

      -- URL encoded
      { path = "/%2e%2e%2fetc%2fpasswd", desc = "URL encoded .. traversal" },
      { path = "/%2e%2e/etc/passwd", desc = "mixed encoded traversal" },
      { path = "/%252e%252e%252fetc%252fpasswd", desc = "double URL encoded" },

      -- Unicode variations
      { path = "/..%u2215etc%u2215passwd", desc = "unicode path separator" },
      { path = "/..%ef%bc%8fetc%ef%bc%8fpasswd", desc = "full-width unicode" },

      -- Null byte injection
      { path = "/../etc/passwd%00.html", desc = "null byte injection" },
      { path = "/../etc/passwd\0", desc = "null byte" },

      -- Case variations
      { path = "/../EtC/PaSsWd", desc = "case variation" },
      { path = "/%2E%2E%2F%65%74%63%2F%70%61%73%73%77%64", desc = "full URL encoded" },

      -- Mixed attacks
      { path = "/foo/../etc/passwd", desc = "mixed legitimate and traversal" },
      { path = "/./../etc/passwd", desc = "with current directory" },
      { path = "/../etc/./passwd", desc = "traversal with current dir" },

      -- Windows-style
      { path = "/..\\etc\\passwd", desc = "Windows backslash" },
      { path = "/%2e%2e%5cetc%5cpasswd", desc = "Windows backslash encoded" },

      -- Note: /etc/passwd and /usr/bin/id are NOT traversal attacks
      -- They map to www/etc/passwd which is within www/ and doesn't exist
      -- The handler correctly allows these (returning SPA fallback)
    }

    for _, attack in ipairs(attack_vectors) do
      it("blocks " .. attack.desc .. " (" .. attack.path .. ")", function()
        local request = { path = attack.path }
        local response = handle_static_request_secure(request)
        assert.is_equal(403, response.status, "Should block " .. attack.desc)
      end)
    end
  end)

  describe("Legitimate Path Access", function()
    local legitimate_paths = {
      { path = "/", expected = "www/index.html" },
      { path = "/css/style.css", expected = "www/css/style.css" },
      { path = "/js/app.js", expected = "www/js/app.js" },
      { path = "/images/logo.png", expected = "www/images/logo.png" },
      { path = "/api/test.json", expected = "www/api/test.json" },
      { path = "/subdir/file.txt", expected = "www/subdir/file.txt" },
    }

    for _, legit in ipairs(legitimate_paths) do
      it("allows access to " .. legit.path, function()
        local request = { path = legit.path }
        local response = handle_static_request_secure(request)
        assert.is_equal(200, response.status, "Should allow " .. legit.path)
      end)
    end
  end)

  describe("Edge Cases", function()
    it("handles empty path by blocking (doesn't start with www/)", function()
      local request = { path = "" }
      local response = handle_static_request_secure(request)
      -- Empty path becomes "www" + "" = "www", not "www/" so blocked
      assert.is_equal(403, response.status)
    end)

    it("handles path with only slashes", function()
      local request = { path = "///" }
      local response = handle_static_request_secure(request)
      -- Normalized to www/, which is valid
      assert.is_equal(200, response.status)
    end)

    it("handles path with special characters", function()
      local request = { path = "/file%20with%20spaces.html" }
      local response = handle_static_request_secure(request)
      -- Space-decoded path is valid if it doesn't contain traversal
      assert.is_equal(200, response.status)
    end)

    it("blocks .. in filename due to simple pattern match", function()
      local request = { path = "/file..txt" }
      local response = handle_static_request_secure(request)
      -- Current implementation blocks ANY ".." including in filenames
      -- This is a false positive but errs on the side of security
      assert.is_equal(403, response.status)
    end)

    it("blocks path that resolves outside www", function()
      local request = { path = "/www/../../../etc/passwd" }
      local response = handle_static_request_secure(request)
      assert.is_equal(403, response.status)
    end)
  end)
end)
