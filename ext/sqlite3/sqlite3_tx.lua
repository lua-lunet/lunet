--[[
  lunet.sqlite3_tx — transaction wrapper for lunet.sqlite3

  Deliberately standalone. The postgres and mysql drivers ship their own
  equivalent modules (lunet.postgres_tx, lunet.mysql_tx). An application
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
      local sqlite = require("lunet.sqlite3")
      local tx = require("lunet.sqlite3_tx")

      local conn = sqlite.open("app.db")

      local ok, err = tx.transaction(conn, function(t)
          t.exec("DELETE FROM nodes WHERE path = ?", dst)
          local r = t.exec("UPDATE nodes SET path = ? WHERE path = ? AND version = ?",
                           dst, src, version)
          if r.affected_rows == 0 then
              return nil, "version conflict"   -- rolls back the DELETE too
          end
          return true
      end, "IMMEDIATE")

      if not ok then
          if err.poisoned then sqlite.close(conn) end
      end

  Contract
  --------
  * fn receives a tx handle. Only calls made through that handle are part of
    the transaction:
      - t.query(sql, ...)      -> rows (array of row tables); raises on error
      - t.query_row(sql, ...)  -> first row or nil; raises on error
      - t.exec(sql, ...)       -> { affected_rows, last_insert_id }; raises on error
    Use t.exec for INSERT/UPDATE/DELETE: affected_rows is what a
    compare-and-set needs, and t.query does not report it.

  * COMMIT happens only if fn returns a non-nil first value. Returning nil
    (optionally with a reason) rolls back.

  * An error raised inside fn rolls back and is surfaced; it never partially
    commits.

  * Returns fn's first two results on COMMIT, or nil + err after a rollback.

  * err is a table: err.message (also what tostring(err) and concatenation
    give) and err.poisoned. poisoned is true when the BEGIN, COMMIT or
    ROLLBACK itself failed — close the connection rather than reusing it.

  SQLite notes
  ------------
  * Placeholders are ? (not $1).

  * The third argument selects the locking mode, since SQLite's default is
    the one that surprises people:

      "DEFERRED"  (default) no lock until the first read/write. Another
                  writer can take the write lock first, so your first
                  UPDATE inside the transaction can fail with SQLITE_BUSY
                  even though BEGIN succeeded.
      "IMMEDIATE" takes the write lock at BEGIN. Prefer this for any
                  read-then-write sequence, including compare-and-set.
      "EXCLUSIVE" also blocks readers.

    Pass "IMMEDIATE" when the transaction will write. It converts a
    mid-transaction busy failure into an up-front one.

  * Unlike Postgres, a statement error does not poison the session: SQLite
    lets you catch a t.* error inside fn and keep going. Doing so is still
    usually wrong, but it will not fail every subsequent statement.

  * SQLite has no server. "Pinning" here is about not letting a pool hand
    the same handle to another coroutine mid-transaction — a single file
    handle with an open transaction is not shareable.
]]

local native = require("lunet.sqlite3")

local M = {}

-- Sentinel key so a statement failure raised by a tx.* helper is
-- distinguishable from an arbitrary error thrown by fn.
local TX_ERR = {}

local VALID_MODES = { DEFERRED = true, IMMEDIATE = true, EXCLUSIVE = true }

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
---@param conn userdata Connection from lunet.sqlite3 open()
---@param fn function Receives a tx handle; return non-nil to COMMIT
---@param mode string|nil "DEFERRED" (default), "IMMEDIATE" or "EXCLUSIVE"
---@return any|nil result fn's first result on COMMIT, nil after ROLLBACK
---@return any err fn's second result on COMMIT, or the error table
function M.transaction(conn, fn, mode)
    if conn == nil then
        return nil, mkerr("transaction requires a connection", false)
    end
    if type(fn) ~= "function" then
        return nil, mkerr("transaction requires a function", false)
    end

    mode = mode or "DEFERRED"
    if not VALID_MODES[mode] then
        return nil, mkerr("invalid transaction mode: " .. tostring(mode)
            .. " (expected DEFERRED, IMMEDIATE or EXCLUSIVE)", false)
    end

    local began, berr = native.exec(conn, "BEGIN " .. mode)
    if not began then
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
