/*
 * Coroutine Reference Tracing Implementation
 * 
 * This file is only compiled when LUNET_TRACE is defined.
 * It provides runtime tracking of coroutine references to detect leaks.
 */

#ifdef LUNET_TRACE

#include "trace.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* Global trace state */
lunet_trace_state_t lunet_trace_state;

void lunet_trace_init(void) {
  memset(&lunet_trace_state, 0, sizeof(lunet_trace_state));
  fprintf(stderr, "[TRACE] Coroutine reference tracing initialized\n");
}

static int find_or_create_location(const char *file, int line) {
  /* Search for existing location */
  for (int i = 0; i < lunet_trace_state.location_count; i++) {
    if (lunet_trace_state.locations[i].file == file &&
        lunet_trace_state.locations[i].line == line) {
      return i;
    }
  }
  
  /* Create new location if space available */
  if (lunet_trace_state.location_count < LUNET_TRACE_MAX_LOCATIONS) {
    int idx = lunet_trace_state.location_count++;
    lunet_trace_state.locations[idx].file = file;
    lunet_trace_state.locations[idx].line = line;
    lunet_trace_state.locations[idx].count = 0;
    return idx;
  }
  
  /* Overflow - return -1 */
  return -1;
}

void lunet_trace_coref_add(const char *file, int line) {
  lunet_trace_state.coref_balance++;
  lunet_trace_state.coref_total_created++;
  
  /* Track peak */
  if (lunet_trace_state.coref_balance > lunet_trace_state.coref_peak) {
    lunet_trace_state.coref_peak = lunet_trace_state.coref_balance;
  }
  
  /* Track location */
  int loc = find_or_create_location(file, line);
  if (loc >= 0) {
    lunet_trace_state.locations[loc].count++;
  }
  
  fprintf(stderr, "[TRACE] COREF_ADD at %s:%d (balance=%d, total_created=%d)\n",
          file, line, lunet_trace_state.coref_balance, 
          lunet_trace_state.coref_total_created);
}

void lunet_trace_coref_remove(const char *file, int line) {
  lunet_trace_state.coref_balance--;
  lunet_trace_state.coref_total_released++;
  
  /* Track location */
  int loc = find_or_create_location(file, line);
  if (loc >= 0) {
    lunet_trace_state.locations[loc].count--;
  }
  
  fprintf(stderr, "[TRACE] COREF_RELEASE at %s:%d (balance=%d, total_released=%d)\n",
          file, line, lunet_trace_state.coref_balance,
          lunet_trace_state.coref_total_released);
  
  /* Warn on negative balance (double-release) */
  if (lunet_trace_state.coref_balance < 0) {
    fprintf(stderr, "[TRACE] WARNING: Negative coref balance! Possible double-release.\n");
  }
}

void lunet_trace_stack_check(lua_State *L, int expected_base, int expected_delta,
                              const char *file, int line) {
  int actual_top = lua_gettop(L);
  int expected_top = expected_base + expected_delta;
  
  if (actual_top != expected_top) {
    fprintf(stderr, "[TRACE] STACK_CHECK FAILED at %s:%d: "
            "expected top=%d (base=%d + delta=%d), actual=%d\n",
            file, line, expected_top, expected_base, expected_delta, actual_top);
    lunet_trace_state.stack_checks_failed++;
    
    /* Dump stack contents for debugging */
    fprintf(stderr, "[TRACE] Stack contents:\n");
    for (int i = 1; i <= actual_top; i++) {
      int t = lua_type(L, i);
      fprintf(stderr, "[TRACE]   [%d] %s", i, lua_typename(L, t));
      if (t == LUA_TSTRING) {
        fprintf(stderr, " = \"%s\"", lua_tostring(L, i));
      } else if (t == LUA_TNUMBER) {
        fprintf(stderr, " = %g", lua_tonumber(L, i));
      } else if (t == LUA_TBOOLEAN) {
        fprintf(stderr, " = %s", lua_toboolean(L, i) ? "true" : "false");
      }
      fprintf(stderr, "\n");
    }
    
    assert(0 && "Stack check failed");
  } else {
    lunet_trace_state.stack_checks_passed++;
  }
}

void lunet_trace_dump(void) {
  fprintf(stderr, "\n");
  fprintf(stderr, "========================================\n");
  fprintf(stderr, "       LUNET TRACE SUMMARY\n");
  fprintf(stderr, "========================================\n");
  fprintf(stderr, "Coroutine References:\n");
  fprintf(stderr, "  Total created:   %d\n", lunet_trace_state.coref_total_created);
  fprintf(stderr, "  Total released:  %d\n", lunet_trace_state.coref_total_released);
  fprintf(stderr, "  Current balance: %d\n", lunet_trace_state.coref_balance);
  fprintf(stderr, "  Peak concurrent: %d\n", lunet_trace_state.coref_peak);
  fprintf(stderr, "\n");
  fprintf(stderr, "Stack Checks:\n");
  fprintf(stderr, "  Passed: %d\n", lunet_trace_state.stack_checks_passed);
  fprintf(stderr, "  Failed: %d\n", lunet_trace_state.stack_checks_failed);
  fprintf(stderr, "\n");
  
  /* Show locations with outstanding refs (potential leaks) */
  int leak_count = 0;
  for (int i = 0; i < lunet_trace_state.location_count; i++) {
    if (lunet_trace_state.locations[i].count != 0) {
      if (leak_count == 0) {
        fprintf(stderr, "Outstanding references by location:\n");
      }
      fprintf(stderr, "  %s:%d  count=%d\n",
              lunet_trace_state.locations[i].file,
              lunet_trace_state.locations[i].line,
              lunet_trace_state.locations[i].count);
      leak_count++;
    }
  }
  
  if (leak_count == 0 && lunet_trace_state.coref_balance == 0) {
    fprintf(stderr, "All coroutine references properly balanced.\n");
  }
  
  fprintf(stderr, "========================================\n\n");
}

void lunet_trace_assert_balanced(const char *context) {
  if (lunet_trace_state.coref_balance != 0) {
    fprintf(stderr, "[TRACE] ASSERTION FAILED at %s: coref_balance=%d (expected 0)\n",
            context, lunet_trace_state.coref_balance);
    lunet_trace_dump();
    assert(lunet_trace_state.coref_balance == 0);
  }
  
  if (lunet_trace_state.stack_checks_failed > 0) {
    fprintf(stderr, "[TRACE] ASSERTION FAILED at %s: %d stack checks failed\n",
            context, lunet_trace_state.stack_checks_failed);
    assert(lunet_trace_state.stack_checks_failed == 0);
  }
  
  fprintf(stderr, "[TRACE] Assertion passed at %s: all refs balanced\n", context);
}

#endif /* LUNET_TRACE */
