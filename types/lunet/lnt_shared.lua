---@meta

---@class LntSharedDict
local Dict = {} -- luacheck: ignore

---Get the value for `key`.
---Values are polymorphic: strings → strings, numbers → numbers, booleans → booleans.
---@param key string
---@return string|number|boolean|nil value
---@return string|nil error "not found" or other error
---@usage
---```lua
---local cache = require("lunet.lnt_shared").store("demo", 1024 * 1024)
---local val, err = cache:get("key")
---```
function Dict:get(key) end

---Set `key` to `value` (overwrites any existing entry).
---@param key string
---@param value string|number|boolean
---@param ttl number? Seconds until expiry; omit or pass `0` for no expiry (fractional OK)
---@return true|nil ok
---@return string|nil error Error message if failed
function Dict:set(key, value, ttl) end

---Add `key` only if it does not already exist.
---@param key string
---@param value string|number|boolean
---@param ttl number? Seconds until expiry; omit or pass `0` for no expiry
---@return true|nil ok
---@return "already exists"|string|nil error "already exists" if key present, or other error
function Dict:add(key, value, ttl) end

---Replace `key` only if it already exists.
---@param key string
---@param value string|number|boolean
---@param ttl number? Seconds until expiry; omit or pass `0` for no expiry
---@return true|nil ok
---@return "not found"|string|nil error "not found" if key absent, or other error
function Dict:replace(key, value, ttl) end

---Delete a key.
---@param key string
---@return true|nil ok
---@return "not found"|string|nil error "not found" if absent, or other error
function Dict:delete(key) end

---Atomically increment a numeric key by `delta` (default 1).
---If the key does not exist and `init` is provided, initialise it to `init` before incrementing.
---`ttl` applies only to newly created keys; pass `nil` to leave existing key TTL unchanged.
---@param key string
---@param delta number? Default 1
---@param init number? Initial value if key absent
---@param ttl number? TTL for newly created keys; `nil` preserves existing TTL
---@return number|nil new_value The new value on success
---@return string|nil error Error message if failed
function Dict:incr(key, delta, init, ttl) end

---Update the TTL of an existing key.
---Pass `0` or a negative value to remove the expiry.
---@param key string
---@param ttl_secs number New TTL in seconds; `<= 0` removes expiry
---@return true|nil ok
---@return string|nil error "not found" if key absent, or other error
function Dict:expire(key, ttl_secs) end

---Get the remaining TTL in seconds for `key`.
---@param key string
---@return number|nil ttl_seconds Remaining TTL (>= 0), or -1 if key has no expiry
---@return "not found"|string|nil error "not found" if key absent
function Dict:ttl(key) end

---Remove all entries from the dictionary and reset the allocator.
function Dict:flush_all() end

---Scan the dictionary and evict expired entries.
---@param max integer? Limits the number of entries evicted (0 or nil = unlimited)
---@return integer count Number of entries evicted
function Dict:flush_expired(max) end

---Returns the total capacity of the region in bytes.
---@return integer bytes
function Dict:capacity() end

---Returns the approximate number of free bytes in the data area.
---Note: tombstoned entries do not reclaim space until flush_all.
---@return integer bytes
function Dict:free_space() end

---Explicitly close the dictionary handle.
---Safe to call multiple times; also runs automatically at GC time.
---@return true
function Dict:close() end

---@class lunet.lnt_shared
local M = {}

---Open (or reuse) a named shared dictionary.
---Multiple calls with the same name return handles to the same underlying region.
---Minimum 64 KiB; default 1 MiB.
---@param name string Logical name for the dictionary (non-empty)
---@param size_bytes number? Minimum size in bytes (default 1048576, minimum 65536)
---@return LntSharedDict dict
---@usage
---```lua
---local lnt = require("lunet.lnt_shared")
---local cache = lnt.open("my_cache", 1024 * 1024)  -- 1 MiB
---cache:set("key", "value")
---print(cache:get("key"))  --> "value"
---```
function M.open(name, size_bytes) end

---Alias for `open`.
---@param name string
---@param size_bytes number?
---@return LntSharedDict
function M.store(name, size_bytes) end

return M
