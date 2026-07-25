#ifndef LUNET_H
#define LUNET_H

#include <stddef.h>

#include "lunet_exports.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lunet_runtime lunet_runtime_t;

typedef struct {
  const char *executable_path;
  int dangerously_skip_loopback_restriction;
} lunet_runtime_options_t;

LUNET_API int lunet_runtime_init(lunet_runtime_t **out_runtime,
                                 const lunet_runtime_options_t *options,
                                 char *error,
                                 size_t error_len);

LUNET_API int lunet_runtime_run_file(lunet_runtime_t *runtime,
                                     const char *script_path,
                                     int *exit_code,
                                     char *error,
                                     size_t error_len);

LUNET_API int lunet_runtime_run_embedded(lunet_runtime_t *runtime,
                                         const unsigned char *blob,
                                         size_t blob_len,
                                         const char *entry_script,
                                         int *exit_code,
                                         char *error,
                                         size_t error_len);

LUNET_API void lunet_runtime_shutdown(lunet_runtime_t *runtime);

#ifdef __cplusplus
}
#endif

#endif /* LUNET_H */
