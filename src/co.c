#include "co.h"

#include <lauxlib.h>

int lunet_spawn(lua_State *L) {
  luaL_checktype(L, 1, LUA_TFUNCTION);
  // create new coroutine
  lua_State *co = lua_newthread(L);

  // copy function to new coroutine
  lua_pushvalue(L, 1);
  lua_xmove(L, co, 1);

  // start coroutine
  int status = lua_resume(co, 0);
  if (status != LUA_OK && status != LUA_YIELD) {
    fprintf(stderr, "Coroutine error: %s\n", lua_tostring(co, -1));
  }

  // pop coroutine (let gc handle)
  lua_pop(L, 1);

  return 0;
}

int _lunet_ensure_coroutine(lua_State *L, const char *func_name) {
  if (lua_pushthread(L)) {
    lua_pop(L, 1);
    lua_pushfstring(L, "%s must be called from coroutine", func_name);
    return lua_error(L);
  }
  lua_pop(L, 1);  // Pop the thread pushed by lua_pushthread
  if (!lua_isyieldable(L)) {
    lua_pushfstring(L, "%s called in non-yieldable context", func_name);
    return lua_error(L);
  }
  return 0;
}