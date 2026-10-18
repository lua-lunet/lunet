-- lunet.sqlite3: the SQLite driver with the path-keyed handle cache.
--
-- The binary module (lunet.sqlite3core) owns the async I/O: one worker-hop
-- open returning (rw, ro, err), statements dispatched to the worker pool on
-- rw and executed inline on the loop thread on ro. This loader owns the
-- policy on top: open() caches the (rw, ro) pair keyed on the path string so
-- a second open of the same file returns the same pair without re-opening,
-- destroy(path) closes both and clears the entry, and open_raw() bypasses
-- the cache for callers who manage their own lifetimes. C owns one thing,
-- Lua owns the other; neither reaches into the other's job.
--
-- :memory: is the unit-test swap: each open is a fresh private database, so
-- it is never cached. The driver returns one connection as BOTH handles and
-- ro does not enforce read-only there.
--
-- Handle lifetimes: handles from open() are closed via destroy(path);
-- handles from open_raw() are closed per-handle via close().

local core = require("lunet.sqlite3core")

local sqlite3 = {}
local cache = {}

for _, name in ipairs({ "close", "query", "exec", "query_params", "exec_params", "prepare" }) do
  sqlite3[name] = core[name]
end

---Convenience open: returns the cached (rw, ro) pair for this path if one
---exists, otherwise opens a fresh pair and caches it. On failure both
---handles are nil and the error is the third return.
---
---params:
---  path          string  database file; ":memory:" opens a fresh private
---                        in-memory database (never cached, ro is the same
---                        connection and does not enforce read-only)
---  create        string  "WAL"    create the file and set journal_mode=WAL
---                        "NORMAL" create the file, leave the journal mode
---                                at the SQLite default
---                        Without create= the file must already exist:
---                        provisioning is a deployment act and the driver
---                        never makes a sticky change to a file on its own.
---  busy_timeout  integer ms       busy handler on both connections
---  foreign_keys  boolean          PRAGMA foreign_keys on both connections
---  synchronous   string  "OFF"|"NORMAL"|"FULL" on both connections
---
---The passthroughs are applied to both connections before open returns;
---afterwards they are per-connection and last-write-wins:
---  db.exec(handle, "PRAGMA busy_timeout = 5000") overrides one handle only.
---
---The ro handle runs queries and execs INLINE on the loop thread — no
---background thread, no yield. Short hot reads are what it is for; a heavy
---read stalls the loop for its duration.
---@param params table { path = "app.db", create = "WAL" }
---@return lightuserdata|nil rw Read-write connection, nil on error
---@return lightuserdata|nil ro Read-only connection (reads run inline on the loop thread); nil on error
---@return string|nil err Error message if failed
function sqlite3.open(params)
  local path = (type(params) == "table" and params.path) or ":memory:"
  if path ~= ":memory:" then
    local entry = cache[path]
    if entry then
      return entry[1], entry[2]
    end
  end
  local rw, ro, err = core.open(params)
  if rw and path ~= ":memory:" then
    cache[path] = { rw, ro }
  end
  return rw, ro, err
end

---Raw open: always opens a fresh (rw, ro, err) pair, bypassing the cache.
---The caller owns the lifetimes and closes each handle with close().
---Takes the same params table as open(); :memory: returns the same
---connection as both handles.
---@param params table Connection parameters
---@return lightuserdata|nil rw Read-write connection, nil on error
---@return lightuserdata|nil ro Read-only connection; nil on error
---@return string|nil err Error message if failed
function sqlite3.open_raw(params)
  return core.open(params)
end

---Close both cached handles for a path and clear the cache entry. Closing
---a path that was never opened (or already destroyed) is a no-op.
---@param path string The path the handles were opened with
function sqlite3.destroy(path)
  local entry = cache[path]
  if not entry then
    return
  end
  cache[path] = nil
  core.close(entry[1])
  core.close(entry[2])
end

return sqlite3
