#ifndef MYSQL_H
#define MYSQL_H

#include <lua.h>

int lunet_mysql_open(lua_State* L);
int lunet_mysql_close(lua_State* L);
int lunet_mysql_query(lua_State* L);
int lunet_mysql_exec(lua_State* L);
#endif