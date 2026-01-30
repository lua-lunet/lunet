#ifndef FS_H
#define FS_H

#include "lunet_lua.h"

int lunet_fs_open(lua_State *L);
int lunet_fs_close(lua_State *L);
int lunet_fs_read(lua_State *L);
int lunet_fs_write(lua_State *L);
int lunet_fs_stat(lua_State *L);
int lunet_fs_scandir(lua_State *L);
#endif