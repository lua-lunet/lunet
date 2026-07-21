#ifndef LUNET_GRAPHLITE_H
#define LUNET_GRAPHLITE_H

#include "lunet_lua.h"

int lunet_graphlite_open(lua_State* L);
int lunet_graphlite_close(lua_State* L);
int lunet_graphlite_query(lua_State* L);
int lunet_graphlite_create_session(lua_State* L);
int lunet_graphlite_close_session(lua_State* L);
int lunet_graphlite_version(lua_State* L);

#endif
