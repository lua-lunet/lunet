#ifndef LUNET_EMBED_SCRIPTS_H
#define LUNET_EMBED_SCRIPTS_H

#include <stddef.h>
#include "lunet_lua.h"

#ifndef LUNET_EMBED_PATH_MAX
#define LUNET_EMBED_PATH_MAX 4096
#endif

int lunet_embed_scripts_prepare(lua_State *L,
                                const unsigned char *blob,
                                size_t blob_len,
                                char *out_dir,
                                size_t out_dir_len,
                                char *err,
                                size_t err_len);

int lunet_embed_scripts_resolve_script(const char *embed_dir,
                                       const char *script_arg,
                                       char *out_script,
                                       size_t out_script_len,
                                       char *err,
                                       size_t err_len);

int lunet_embed_scripts_validate_relative_path(const char *script_arg,
                                               char *err,
                                               size_t err_len);

void lunet_embed_scripts_cleanup(const char *embed_dir);

#endif /* LUNET_EMBED_SCRIPTS_H */
