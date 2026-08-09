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
      -- httpc.request guards on running in a coroutine before validating, so
      -- call inside one; the validation error returns synchronously (no yield).
      local co = coroutine.create(function()
        return httpc.request({})
      end)
      local resumed, resp, err = coroutine.resume(co)
      assert.is_true(resumed)
      assert.is_nil(resp)
      assert.are.equal("string", type(err))
    end)
  end)
end)
