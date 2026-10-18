#ifndef LUNET_LUNET_DB_MYSQL_H
#define LUNET_LUNET_DB_MYSQL_H

#include "lunet_lua.h"

// Connection functions
int lunet_db_open(lua_State* L);
int lunet_db_close(lua_State* L);

// Legacy functions (will be refactored to use prepared statements internally)
int lunet_db_query(lua_State* L);
int lunet_db_exec(lua_State* L);

// New prepared statement functions
int lunet_db_query_params(lua_State* L);  // query with parameters
int lunet_db_exec_params(lua_State* L);   // exec with parameters

// Explicit prepared statements: db.prepare(handle, sql) returns a reusable
// statement handle with query/exec/close methods.
int lunet_db_prepare(lua_State* L);

#endif