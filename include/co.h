#ifndef CO_H
#define CO_H

#include <lua.h>
int lunet_spawn(lua_State *L);
int lunet_ensure_coroutine(lua_State *L, const char *func_name);
#endif  // CO_H