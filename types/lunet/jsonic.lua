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

---Render a value as a quoted JSON string (fixed-shape helper).
---Strings are quoted with the same escaper `encode` uses; any other value
---falls back to `encode`.
---@param value any The value to render
---@return string json
---@usage
---```lua
---local json = require("lunet.jsonic")
---local s = json.jstr('say "hi"')
---print(s)  --> '"say \"hi\""'
---```
function jsonic.jstr(value) end

---Render a value as a JSON number (fixed-shape helper).
---Intended for integers; the output is byte-identical to `encode`.
---@param value any The value to render
---@return string json
---@usage
---```lua
---local json = require("lunet.jsonic")
---local s = json.jint(42)
---print(s)  --> '42'
---```
function jsonic.jint(value) end

---Sentinel value representing JSON null (from dkjson).
---@type any
jsonic.null = nil

return jsonic
