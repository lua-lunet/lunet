-- lunet.sqlite3: the SQLite driver.
--
-- The binary module (lunet.sqlite3core) owns the async I/O: one worker-hop
-- open returning (rw, ro, err), statements dispatched to the worker pool on
-- rw and executed inline on the loop thread on ro. This loader passes the
-- option surface through; the ownership contract is #217's: the rw handle
-- has one dedicated background worker thread, the ro handle runs inline on
-- the event loop.
--
-- :memory: is the unit-test swap: each open is a fresh private database.
-- The driver returns one connection as BOTH handles and ro does not
-- enforce read-only there.
--
-- Handles are closed per-handle via close().

local core = require("lunet.sqlite3core")

local sqlite3 = {}

for _, name in ipairs({ "close", "query", "exec", "query_params", "exec_params", "prepare" }) do
  sqlite3[name] = core[name]
end

sqlite3.open = core.open

return sqlite3
