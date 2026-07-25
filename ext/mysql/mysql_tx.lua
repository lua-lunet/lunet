--[[
  lunet.mysql_tx — transaction wrapper for lunet.mysql

  Deliberately standalone. The postgres and sqlite3 drivers ship their own
  equivalent modules (lunet.postgres_tx, lunet.sqlite3_tx). An application
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
      local mysql = require("lunet.mysql")
      local tx = require("lunet.mysql_tx")

      local conn = mysql.open(cfg)

      local ok, err = tx.transaction(conn, function(t)
          t.exec("DELETE FROM nodes WHERE path = ?", dst)
          local r = t.exec("UPDATE nodes SET path = ? WHERE path = ? AND version = ?",
                           dst, src, version)
          if r.affected_rows == 0 then
              return nil, "version conflict"   -- rolls back the DELETE too
          end
          return true
      end)

      if not ok then
          if err.poisoned then mysql.close(conn) end
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

  MySQL notes
  -----------
  * Placeholders are ? (not $1).

  * This wrapper brackets the transaction with SET autocommit=0 / COMMIT /
    SET autocommit=1 rather than BEGIN, because lunet.mysql cannot issue
    BEGIN at all. Unlike the postgres driver (which falls back to PQexec when
    no parameters are bound), ext/mysql/mysql.c always goes through
    mysql_stmt_prepare, and MySQL's prepared-statement protocol rejects
    BEGIN, START TRANSACTION and SAVEPOINT with "This command is not
    supported in the prepared statement protocol yet". COMMIT, ROLLBACK and
    SET autocommit are accepted, so those are what this module uses.
    Consequence: savepoints (nested transactions) are not available here.

  * Because the transaction is opened by turning autocommit off, restoring
    it afterwards is part of the contract. If that restore fails the
    connection is left in manual-commit mode, which would silently swallow
    the next caller's writes, so it is reported as poisoned.

  * The storage engine has to be transactional. On a MyISAM table, BEGIN and
    COMMIT succeed and do nothing at all — there is no error to detect, the
    writes simply are not atomic and ROLLBACK does not undo them. Use
    InnoDB. This wrapper cannot check for you, because MySQL reports no
    problem.

  * DDL causes an implicit commit. CREATE, ALTER, DROP, TRUNCATE and RENAME
    silently commit everything issued before them and cannot be rolled back.
    Never issue DDL inside fn: a later rollback will not undo the DML that
    preceded it. Keep migrations outside transactions.

  * MySQL's default isolation level is REPEATABLE READ, not the READ
    COMMITTED that Postgres uses. A repeated SELECT inside one transaction
    keeps returning the snapshot from the first read, so a
    read-check-then-write against concurrently changing rows needs the
    affected_rows result of t.exec to detect the conflict, not a re-SELECT.

  * On lock wait timeout or deadlock, MySQL may have already rolled the
    transaction back on its own. The statement error unwinds to the ROLLBACK
    here, which then succeeds as a no-op, so this is handled — but a
    deadlock is a retryable condition, and retrying is the caller's decision.
]]

local native = require("lunet.mysql")

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
---@param conn userdata Connection from lunet.mysql open()
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

    -- Not BEGIN: MySQL's prepared-statement protocol rejects it, and this
    -- driver has no non-prepared path. Turning autocommit off opens the
    -- transaction instead. See the MySQL notes above.
    local began, berr = native.exec(conn, "SET autocommit=0")
    if not began then
        return nil, mkerr(berr or "SET autocommit=0 failed", true)
    end

    -- Restore autocommit before handing the connection back. A connection
    -- left in manual-commit mode would silently buffer the next caller's
    -- writes, so a failed restore poisons it.
    local function restore()
        local ok_restore, rerr = native.exec(conn, "SET autocommit=1")
        if not ok_restore then
            return "autocommit could not be restored: " .. tostring(rerr)
        end
        return nil
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
            restore()
            return nil, mkerr(cerr or "COMMIT failed", true)
        end
        local restore_err = restore()
        if restore_err then
            -- The data is committed, but the connection is not safe to reuse.
            return nil, mkerr(restore_err, true)
        end
        return r1, r2
    end

    -- Abort path: fn raised, or returned nil to signal rollback.
    local rolled, rerr = native.exec(conn, "ROLLBACK")
    local restore_err = restore()
    local poisoned = (not rolled) or (restore_err ~= nil)

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

    if not rolled then
        message = message .. " (ROLLBACK also failed: " .. tostring(rerr) .. ")"
    end
    if restore_err then
        message = message .. " (" .. restore_err .. ")"
    end

    return nil, mkerr(message, poisoned)
end

return M
