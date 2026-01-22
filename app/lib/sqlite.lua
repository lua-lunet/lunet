local ffi = require("ffi")

ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;

int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close(sqlite3*);
const char *sqlite3_errmsg(sqlite3*);

int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt*);

int sqlite3_column_count(sqlite3_stmt*);
const char *sqlite3_column_name(sqlite3_stmt*, int N);
int sqlite3_column_type(sqlite3_stmt*, int iCol);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt*, int iCol);
double sqlite3_column_double(sqlite3_stmt*, int iCol);
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);

int sqlite3_exec(sqlite3*, const char *sql, void*, void*, char **errmsg);
void sqlite3_free(void*);

int sqlite3_changes(sqlite3*);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3*);

int sqlite3_busy_timeout(sqlite3*, int ms);
]]

local M = {}

local SQLITE_ROW = 100
local SQLITE_DONE = 101

local SQLITE_INTEGER = 1
local SQLITE_FLOAT = 2
local SQLITE_TEXT = 3
local SQLITE_BLOB = 4
local SQLITE_NULL = 5

local OPEN_READWRITE = 0x00000002
local OPEN_CREATE = 0x00000004

local lib = ffi.load("sqlite3")

local function errstr(db)
  if db == nil then
    return "sqlite3: no db handle"
  end
  local msg = lib.sqlite3_errmsg(db)
  if msg == nil then
    return "sqlite3: unknown error"
  end
  return ffi.string(msg)
end

function M.open(path)
  local pp = ffi.new("sqlite3*[1]")
  local rc = lib.sqlite3_open_v2(path, pp, bit.bor(OPEN_READWRITE, OPEN_CREATE), nil)
  local db = pp[0]
  if rc ~= 0 or db == nil then
    return nil, "sqlite3_open_v2 failed: " .. errstr(db)
  end
  lib.sqlite3_busy_timeout(db, 3000)
  return db
end

function M.close(db)
  if db ~= nil then
    lib.sqlite3_close(db)
  end
end

function M.exec(db, sql)
  local errmsg = ffi.new("char*[1]")
  local rc = lib.sqlite3_exec(db, sql, nil, nil, errmsg)
  if rc ~= 0 then
    local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or errstr(db)
    if errmsg[0] ~= nil then
      lib.sqlite3_free(errmsg[0])
    end
    return nil, msg
  end

  return {
    affected_rows = tonumber(lib.sqlite3_changes(db)),
    last_insert_id = tonumber(lib.sqlite3_last_insert_rowid(db)),
  }
end

function M.query(db, sql)
  local stmtpp = ffi.new("sqlite3_stmt*[1]")
  local rc = lib.sqlite3_prepare_v2(db, sql, #sql, stmtpp, nil)
  local stmt = stmtpp[0]
  if rc ~= 0 or stmt == nil then
    if stmt ~= nil then
      lib.sqlite3_finalize(stmt)
    end
    return nil, "sqlite3_prepare_v2 failed: " .. errstr(db)
  end

  local cols = lib.sqlite3_column_count(stmt)
  local colnames = {}
  for i = 0, cols - 1 do
    local name = lib.sqlite3_column_name(stmt, i)
    colnames[i] = name ~= nil and ffi.string(name) or ("col" .. tostring(i + 1))
  end

  local function fetch_rows()
    local rows = {}
    while true do
      local step_rc = lib.sqlite3_step(stmt)
      if step_rc == SQLITE_ROW then
        local row = {}
        for i = 0, cols - 1 do
          local t = lib.sqlite3_column_type(stmt, i)
          local key = colnames[i]
          if t == SQLITE_NULL then
            row[key] = nil
          elseif t == SQLITE_INTEGER then
            row[key] = tonumber(lib.sqlite3_column_int64(stmt, i))
          elseif t == SQLITE_FLOAT then
            row[key] = tonumber(lib.sqlite3_column_double(stmt, i))
          elseif t == SQLITE_TEXT or t == SQLITE_BLOB then
            local p = lib.sqlite3_column_text(stmt, i)
            row[key] = p ~= nil and ffi.string(p) or ""
          end
        end
        rows[#rows + 1] = row
      elseif step_rc == SQLITE_DONE then
        break
      else
        return nil, "sqlite3_step failed: " .. errstr(db)
      end
    end
    return rows
  end

  local ok, res, err = pcall(fetch_rows)
  lib.sqlite3_finalize(stmt)
  
  if not ok then
    return nil, res
  end
  return res, err
end

return M
