#ifndef SU_H
#define SU_H

#include <lua.h>

// lunet.su module:
//   su, err = require('lunet.su').open(dir, max_addresses)
int lunet_su_open(lua_State *L);

#endif  // SU_H
