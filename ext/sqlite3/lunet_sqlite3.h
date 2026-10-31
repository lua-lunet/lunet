#ifndef LUNET_DB_SQLITE3_H
#define LUNET_DB_SQLITE3_H

#include "lunet_lua.h"

int lunet_db_open(lua_State* L);
int lunet_db_close(lua_State* L);
int lunet_db_query_ro(lua_State* L);
int lunet_db_query(lua_State* L);
int lunet_db_exec(lua_State* L);
int lunet_db_query_params(lua_State* L);
int lunet_db_exec_params(lua_State* L);
int lunet_db_prepare(lua_State* L);
int lunet_db_run_in_transaction(lua_State* L);

#endif
