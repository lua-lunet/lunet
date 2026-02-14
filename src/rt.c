#include "rt.h"
#include "lunet_exports.h"
#include "lunet_mem.h"
#include "trace.h"
#include <stddef.h>

static lua_State *g_luaL = NULL;

LUNET_API void set_default_luaL(lua_State *L) { g_luaL = L; }

LUNET_API lua_State *default_luaL(void) { return g_luaL; }

LUNET_API void lunet_init_core(lua_State *L) {
    static int initialized = 0;
    if (initialized) return;
    initialized = 1;
    
    set_default_luaL(L);
    lunet_mem_init();
    lunet_trace_init();
}
