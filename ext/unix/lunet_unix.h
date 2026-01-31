/**
 * lunet_unix.h - Unix domain socket extension for lunet
 *
 * This module provides Unix domain socket (IPC) support as a separate
 * extension, loadable via require("lunet.unix").
 *
 * API:
 *   unix.listen(path)          -> listener, err
 *   unix.accept(listener)      -> client, err
 *   unix.connect(path)         -> client, err
 *   unix.read(client)          -> data, err
 *   unix.write(client, data)   -> err
 *   unix.close(handle)         -> err
 *   unix.getpeername(client)   -> name, err
 *   unix.unlink(path)          -> err (remove socket file)
 */

#ifndef LUNET_UNIX_H
#define LUNET_UNIX_H

#include "lunet_lua.h"

/**
 * Listen on a Unix domain socket.
 * Lua: unix.listen(path) -> listener, err
 */
int lunet_unix_listen(lua_State *L);

/**
 * Accept a connection on a Unix socket listener.
 * Lua: unix.accept(listener) -> client, err
 */
int lunet_unix_accept(lua_State *L);

/**
 * Connect to a Unix domain socket.
 * Lua: unix.connect(path) -> client, err
 */
int lunet_unix_connect(lua_State *L);

/**
 * Read data from a Unix socket client.
 * Lua: unix.read(client) -> data, err
 */
int lunet_unix_read(lua_State *L);

/**
 * Write data to a Unix socket client.
 * Lua: unix.write(client, data) -> err
 */
int lunet_unix_write(lua_State *L);

/**
 * Close a Unix socket (listener or client).
 * Lua: unix.close(handle) -> err
 */
int lunet_unix_close(lua_State *L);

/**
 * Get peer name for a Unix socket client.
 * Lua: unix.getpeername(client) -> name, err
 */
int lunet_unix_getpeername(lua_State *L);

/**
 * Remove a Unix socket file (convenience wrapper for cleanup).
 * Lua: unix.unlink(path) -> err
 */
int lunet_unix_unlink(lua_State *L);

/**
 * Set read buffer size (optional tuning).
 * Lua: unix.set_read_buffer_size(size) -> nil
 */
int lunet_unix_set_read_buffer_size(lua_State *L);

#endif /* LUNET_UNIX_H */
