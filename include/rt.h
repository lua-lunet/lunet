#ifndef RT_H
#define RT_H

#include <lua.h>
void set_default_luaL(lua_State *L);
lua_State *default_luaL(void);
#endif // RT_H
