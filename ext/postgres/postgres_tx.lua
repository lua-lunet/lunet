--[[
  lunet.postgres_tx — transaction wrapper for lunet.postgres

  Deliberately standalone. The sqlite3 and mysql drivers ship their own
  equivalent modules (lunet.sqlite3_tx, lunet.mysql_tx). An application
  builds one driver, not three, and the three databases differ in ways a
  shared abstraction would have to paper over. These files are free to
  diverge.

  Why this exists
  ---------------
  A transaction lives on a *connection*, not on a coroutine. The trap this
  module closes is the natural-looking connection pool that checks a
  connection out per call and returns it afterwards:

      db.query(cfg, "BEGIN")     -- connection A
      db.query(cfg, "UPDATE ...")-- connection B  <-- not in the transaction
      db.query(cfg, "COMMIT")    -- connection C  <-- commits nothing

  transaction() takes the connection itself and holds it for the whole
  transaction, so there is no window in which a pool could hand it to
  someone else.

  Usage
  -----
      local pg = require("lunet.postgres")
      local tx = require("lunet.postgres_tx")

      local conn = pg.open(cfg)

      local moved, err = tx.transaction(conn, function(t)
          t.exec("DELETE FROM nodes WHERE path = $1", dst)
          local r = t.exec("UPDATE nodes SET path = $1 WHERE path = $2 AND version = $3",
                           dst, src, version)
          if r.affected_rows == 0 then
              return nil, "version conflict"   -- rolls back the DELETE too
          end
          return true
      end)

      if not moved then
          -- poisoned means the session state is unknown: close, don't reuse.
          if err.poisoned then pg.close(conn) end
      end

  Contract
  --------
  * fn receives a tx handle. Only calls made through that handle are part of
    the transaction:
      - t.query(sql, ...)      -> rows (array of row tables); raises on error
      - t.query_row(sql, ...)  -> first row or nil; raises on error
      - t.exec(sql, ...)       -> { affected_rows }; raises on error
    Use t.exec for INSERT/UPDATE/DELETE: affected_rows is what a
    compare-and-set needs, and t.query does not report it.

  * COMMIT happens only if fn returns a non-nil first value. Returning nil
    (optionally with a reason) rolls back. This is what lets an
    optimistic-concurrency miss — an UPDATE ... WHERE version = $n matching
    zero rows — undo earlier statements instead of committing half the work.

  * An error raised inside fn rolls back and is surfaced; it never partially
    commits.

  * Returns fn's first two results on COMMIT, or nil + err after a rollback.

  * err is a table: err.message (also what tostring(err) and concatenation
    give) and err.poisoned. poisoned is true when BEGIN, COMMIT or ROLLBACK
    itself failed, which leaves the session in an unknown state — close the
    connection instead of returning it to a pool.

  Postgres notes
  --------------
  * Placeholders are $1, $2, ... (not ?).

  * A statement carrying bound parameters must be a single command. That is
    libpq's extended-query protocol, not a lunet restriction; the driver
    routes parameterised statements through PQexecParams. Statements with no
    parameters go through PQexec and may contain several commands separated
    by ';', but only the last command's results come back — so do not try to
    smuggle a whole transaction into one string.

  * After any statement error inside a transaction, Postgres puts the
    session in an aborted state where every further statement fails until
    ROLLBACK. Because a raise unwinds straight to the ROLLBACK here, that is
    handled; but do not catch a t.* error inside fn and carry on issuing
    statements, because they will all fail.
]]

local native = require("lunet.postgres")

local M = {}

-- Sentinel key so a statement failure raised by a tx.* helper is
-- distinguishable from an arbitrary error thrown by fn.
local TX_ERR = {}

local function text(v)
    if type(v) == "table" and v.message ~= nil then
        return v.message
    end
    return tostring(v)
end

local err_mt = {
    __tostring = function(e) return e.message end,
    __concat = function(a, b) return text(a) .. text(b) end,
}

local function mkerr(message, poisoned)
    return setmetatable({
        message = message or "unknown error",
        poisoned = poisoned and true or false,
    }, err_mt)
end

---Run fn inside a transaction on one pinned connection.
---@param conn userdata Connection from lunet.postgres open()
---@param fn function Receives a tx handle; return non-nil to COMMIT
---@return any|nil result fn's first result on COMMIT, nil after ROLLBACK
---@return any err fn's second result on COMMIT, or the error table
function M.transaction(conn, fn)
    if conn == nil then
        return nil, mkerr("transaction requires a connection", false)
    end
    if type(fn) ~= "function" then
        return nil, mkerr("transaction requires a function", false)
    end

    local began, berr = native.exec(conn, "BEGIN")
    if not began then
        -- Nothing was started, but we cannot tell why BEGIN failed, so the
        -- session state is unknown.
        return nil, mkerr(berr or "BEGIN failed", true)
    end

    local tx = {}

    function tx.query(sql, ...)
        local rows, e = native.query(conn, sql, ...)
        if not rows then
            error({ [TX_ERR] = e or "query failed" }, 0)
        end
        return rows
    end

    function tx.query_row(sql, ...)
        return tx.query(sql, ...)[1]
    end

    function tx.exec(sql, ...)
        local res, e = native.exec(conn, sql, ...)
        if not res then
            error({ [TX_ERR] = e or "exec failed" }, 0)
        end
        return res
    end

    local ok, r1, r2 = pcall(fn, tx)

    -- Commit path: fn completed and asked for a commit.
    if ok and r1 ~= nil then
        local committed, cerr = native.exec(conn, "COMMIT")
        if not committed then
            return nil, mkerr(cerr or "COMMIT failed", true)
        end
        return r1, r2
    end

    -- Abort path: fn raised, or returned nil to signal rollback.
    local rolled, rerr = native.exec(conn, "ROLLBACK")
    local poisoned = not rolled

    local message
    if not ok then
        if type(r1) == "table" and r1[TX_ERR] ~= nil then
            message = r1[TX_ERR]
        else
            message = text(r1)
        end
    else
        message = r2 ~= nil and text(r2) or "transaction aborted"
    end

    if poisoned then
        message = message .. " (ROLLBACK also failed: " .. tostring(rerr) .. ")"
    end

    return nil, mkerr(message, poisoned)
end

return M
