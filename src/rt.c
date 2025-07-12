#include "rt.h"

static lua_State *g_luaL = NULL;

void set_default_luaL(lua_State *L) { g_luaL = L; }

lua_State *default_luaL(void) { return g_luaL; }