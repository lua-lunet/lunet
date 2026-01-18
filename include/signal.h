#ifndef LUNET_SIGNAL_H
#define LUNET_SIGNAL_H

#include <lua.h>

// NOTE: This project provides a module header named `signal.h`, which can
// shadow the system `<signal.h>` when building with `-Iinclude`.
// Pull in the system header explicitly so SIGINT/SIGTERM/etc are available.
#if defined(__GNUC__) || defined(__clang__)
#include_next <signal.h>
#endif

int lunet_signal_wait(lua_State *L);

#endif  // LUNET_SIGNAL_H