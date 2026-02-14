#ifndef RT_H
#define RT_H

#include "lunet_lua.h"
#include "lunet_exports.h"

LUNET_API void set_default_luaL(lua_State *L);
LUNET_API lua_State *default_luaL(void);
LUNET_API void lunet_init_core(lua_State *L);

#endif // RT_H
