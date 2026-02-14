/*
 * easy_memory implementation translation unit for Lunet
 *
 * This file compiles easy_memory.h into its own object file so the rest
 * of the project only needs to include the header without worrying about
 * the EASY_MEMORY_IMPLEMENTATION guard.
 *
 * Build-time defines applied by xmake when --easy_memory=y:
 *   LUNET_EASY_MEMORY          - always set
 *   EM_ASSERT_STAYS            - when LUNET_TRACE is also active
 *   EM_POISONING               - when LUNET_TRACE is also active
 *   EM_SAFETY_POLICY=0         - CONTRACT mode for trace builds (crashes on misuse)
 *   EM_SAFETY_POLICY=1         - DEFENSIVE mode for release builds (graceful NULL)
 */

#ifdef LUNET_EASY_MEMORY

#define EASY_MEMORY_IMPLEMENTATION
#include "easy_memory.h"

#endif /* LUNET_EASY_MEMORY */
