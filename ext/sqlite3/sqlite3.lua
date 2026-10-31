-- lunet.sqlite3: the SQLite driver.
--
-- The binary module (lunet.sqlite3core) owns the async I/O and the
-- ownership machine: the ro handle runs inline on the event loop (one
-- transient statement per call, no yield); the rw handle is owned by one
-- dedicated background worker thread with FIFO dispatch; close on rw
-- drains the accepted work first. This loader passes the whole option
-- surface through unchanged.
--
-- :memory: is the testing substitution: one physical connection serves
-- both logical paths, serialized through its owner worker, and read-only
-- is not enforced there.
--
-- The opt-in helper is connect(): it starts from synchronous = "NORMAL"
-- and copies caller options over that default. The raw open() never
-- acquires the helper's default.
--
-- Handles are closed per-handle via close().

local core = require("lunet.sqlite3core")

local sqlite3 = {}

for _, name in ipairs({ "close", "query", "query_ro", "exec",
                        "query_params", "exec_params", "prepare",
                        "run_in_transaction" }) do
  sqlite3[name] = core[name]
end

sqlite3.open = core.open

function sqlite3.connect(path, opts)
  local params = {}
  if opts then
    for k, v in pairs(opts) do
      params[k] = v
    end
  end
  if params.synchronous == nil then
    params.synchronous = "NORMAL"
  end
  params.path = path
  return core.open(params)
end

return sqlite3
