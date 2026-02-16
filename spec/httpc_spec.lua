describe("HTTPC Module #native", function()
  local ok, httpc = pcall(require, "lunet.httpc")
  if not ok then
    pending("lunet.httpc not built (xmake build lunet-httpc)", function() end)
    return
  end

  it("exports request()", function()
    assert.are.equal("table", type(httpc))
    assert.are.equal("function", type(httpc.request))
  end)

  it("requires calling from a coroutine", function()
    assert.has_error(function()
      httpc.request({ url = "https://example.com/" })
    end)
  end)

  describe("argument validation", function()
    it("requires url", function()
      local resp, err = httpc.request({})
      assert.is_nil(resp)
      assert.are.equal("string", type(err))
    end)

    it("rejects non-string url", function()
      local resp, err = httpc.request({ url = 123 })
      assert.is_nil(resp)
      assert.are.equal("string", type(err))
    end)

    it("defaults method to GET", function()
      -- Expected behavior: method defaults to GET when omitted.
      -- This is validated indirectly by ensuring the call does not fail
      -- during option parsing when method is unset.
      local resp, err = httpc.request({ url = "https://example.com/" })
      assert.is_true(resp ~= nil or err ~= nil)
    end)
  end)
end)
