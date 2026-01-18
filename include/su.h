#ifndef SU_H
#define SU_H

#include <lua.h>

int lunet_su_init(lua_State *L);
int lunet_su_read(lua_State *L);
int lunet_su_write(lua_State *L);

#endif // SU_H
