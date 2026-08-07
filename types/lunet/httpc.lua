---@meta

---@class lunet.httpc
local httpc = {}

---Perform an HTTP request (must be called from a coroutine).
---
---This is non-blocking under the lunet scheduler: a sibling coroutine keeps
---running while the request is in flight.
---
---4xx and 5xx status codes arrive as normal responses (not errors).
---Only transport-level failures (connect, timeout, DNS) return `nil, err`.
---
---Unknown keys in `opts` are silently accepted and ignored.
---
---@param opts table Options table
--- - url: string (required) The URL to request
--- - method: string? HTTP method; defaults to "GET"
--- - body: string? Request body payload
--- - headers: table<string, string>? Request headers as a name-value map
--- - timeout_ms: integer? Request timeout in milliseconds (default 30000)
--- - max_body_bytes: integer? Maximum response body size in bytes (default unlimited)
---@return table|nil response On success: { status = integer, body = string,
--- headers = { {name=string, value=string} }, effective_url = string }
---@return string error Error message if transport-level failure
---@usage
---```lua
---local httpc = require("lunet.httpc")
---lunet.spawn(function()
---    local resp, err = httpc.request({
---        url = "https://httpbin.org/json",
---        method = "GET",
---        timeout_ms = 5000,
---    })
---    if not resp then
---        print("request failed: " .. err)
---        return
---    end
---    print("status:", resp.status)
---    print("body:", resp.body)
---end)
---```
function httpc.request(opts) end

return httpc
