---@meta

---@class lunet.jsonic
local jsonic = {}

---Decode a JSON string.
---@param str string The JSON string to decode
---@param position integer? Start position in `str` (default 1)
---@param nullval any? Value to use for JSON null (default jsonic.null)
---@return any value The decoded Lua value
---@return integer next_position Position after the decoded value
---@return string|nil error Error message on parse failure, or nil on success
---@usage
---```lua
---local json = require("lunet.jsonic")
---local v, pos, err = json.decode('{"a":1,"s":"ok"}')
---print(v.a, v.s)  --> 1  "ok"
---```
function jsonic.decode(str, position, nullval) end

---Encode a Lua value to a JSON string (via dkjson backend).
---@param value any The value to encode
---@param opts table? Options forwarded to dkjson.encode (e.g. { keyorder = {"a","b"} })
---@return string json
---@usage
---```lua
---local json = require("lunet.jsonic")
---local s = json.encode({ a = 1, b = "x" }, { keyorder = { "a", "b" } })
---print(s)  --> '{"a":1,"b":"x"}'
---```
function jsonic.encode(value, opts) end

---Sentinel value representing JSON null (from dkjson).
---@type any
jsonic.null = nil

return jsonic
