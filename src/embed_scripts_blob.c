#include "embed_scripts_blob.h"

#ifdef LUNET_EMBED_SCRIPTS
#include "lunet_embed_scripts_blob.h"
#else
const unsigned char lunet_embedded_scripts_gzip[] = {0};
const size_t lunet_embedded_scripts_gzip_len = 0;
#endif
