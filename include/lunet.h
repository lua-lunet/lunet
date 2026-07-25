#ifndef LUNET_H
#define LUNET_H

#include <stddef.h>

#include "lunet_exports.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Lunet embedding API.
 *
 * Contract (also documented in docs/EMBEDDING.md):
 *
 * - One runtime per process, and one successful lunet_runtime_init() per
 *   process lifetime: after shutdown, a later init attempt fails, because
 *   Lunet uses a single default Lua state and libuv default loop.
 * - One application run per runtime: call lunet_runtime_run_file() or
 *   lunet_runtime_run_embedded() exactly once. A failed run still consumes
 *   the runtime; shut it down afterwards.
 * - Not thread-safe: call all four functions from the same thread that
 *   initialised the runtime, with no concurrent calls.
 * - Every function may take error == NULL with error_len == 0; diagnostics
 *   are optional. error is always NUL-terminated when error_len > 0.
 * - Return value is the API status (0 on success, -1 on failure). The
 *   application exit code is reported separately through exit_code.
 */
typedef struct lunet_runtime lunet_runtime_t;

typedef struct {
  /* Path of the host executable (typically argv[0]). Used to prepend the
   * executable's directory to package.cpath so sibling extension modules
   * are found. May be NULL or empty to skip. */
  const char *executable_path;
  /* Set to 1 to allow binding to non-loopback interfaces. Default 0 keeps
   * the loopback-only network restriction. */
  int dangerously_skip_loopback_restriction;
} lunet_runtime_options_t;

/* Create the single process runtime. options may be NULL (defaults). */
LUNET_API int lunet_runtime_init(lunet_runtime_t **out_runtime,
                                 const lunet_runtime_options_t *options,
                                 char *error,
                                 size_t error_len);

/* Run a Lua application from the filesystem. Consumes the runtime's one
 * run, blocks until the event loop drains, and reports the application
 * exit code (from the Lua global __lunet_exit_code, default 0). */
LUNET_API int lunet_runtime_run_file(lunet_runtime_t *runtime,
                                     const char *script_path,
                                     int *exit_code,
                                     char *error,
                                     size_t error_len);

/* Run a Lua application embedded in a LUNETPK1 gzip blob (produced by
 * bin/generate_embed_scripts.lua). The blob is validated, extracted to a
 * private temp directory, and entry_script must be a safe relative path
 * inside it. Consumes the runtime's one run. */
LUNET_API int lunet_runtime_run_embedded(lunet_runtime_t *runtime,
                                         const unsigned char *blob,
                                         size_t blob_len,
                                         const char *entry_script,
                                         int *exit_code,
                                         char *error,
                                         size_t error_len);

/* Tear down the runtime. Safe to call with NULL. Always call after a
 * successful init, even when the run failed. */
LUNET_API void lunet_runtime_shutdown(lunet_runtime_t *runtime);

#ifdef __cplusplus
}
#endif

#endif /* LUNET_H */
