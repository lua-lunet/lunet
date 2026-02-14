#ifndef RUNTIME_H
#define RUNTIME_H

#include "lunet_exports.h"

// Global runtime configuration flags
typedef struct {
    int dangerously_skip_loopback_restriction;
} lunet_runtime_config_t;

extern LUNET_API lunet_runtime_config_t g_lunet_config;

#endif // RUNTIME_H
