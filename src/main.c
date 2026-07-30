#include <stdio.h>
#include <string.h>

#include "lunet.h"
#include "lunet_lua.h"

#ifdef LUNET_EMBED_SCRIPTS
#include "embed_scripts_blob.h"
#endif

int main(int argc, char **argv) {
  lunet_runtime_options_t options = {0};
  lunet_runtime_t *runtime = NULL;
  char error[512] = {0};
  int exit_code = 1;
  int script_index = 0;

  if (argc < 2) {
    fprintf(stderr, "Usage: %s [OPTIONS] <lua_file>\n", argv[0]);
    fprintf(stderr, "\nOptions:\n");
    fprintf(stderr, "  --dangerously-skip-loopback-restriction\n");
    fprintf(stderr, "      Allow binding to any network interface. By default, binding is restricted\n");
    fprintf(stderr, "      to loopback (127.0.0.1, ::1) or Unix sockets.\n");
    fprintf(stderr, "  --verbose-trace\n");
    fprintf(stderr, "      Enable verbose per-event tracing (debug builds only)\n");
    return 1;
  }

  options.executable_path = argv[0];
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--dangerously-skip-loopback-restriction") == 0) {
      options.dangerously_skip_loopback_restriction = 1;
      fprintf(stderr, "WARNING: Loopback restriction disabled. Binding to public interfaces allowed.\n");
    } else if (strcmp(argv[i], "--verbose-trace") == 0) {
      fprintf(stderr, "Note: verbose tracing is a compile-time option (LUNET_TRACE_VERBOSE); flag ignored.\n");
    } else if (argv[i][0] == '-') {
      fprintf(stderr, "Unknown option: %s\n", argv[i]);
      return 1;
    } else {
      script_index = i;
      break;
    }
  }

  if (script_index == 0) {
    fprintf(stderr, "Error: No script file specified.\n");
    return 1;
  }

  if (lunet_runtime_init(&runtime, &options, error, sizeof(error)) != 0) {
    fprintf(stderr, "Error: %s\n", error);
    return 1;
  }

  /* Set up the arg global for the Lua script */
  lua_State *L = (lua_State *)lunet_runtime_get_lua_state(runtime);
  if (L) {
    lua_newtable(L);
    for (int i = script_index; i < argc; i++) {
      lua_pushstring(L, argv[i]);
      lua_rawseti(L, -2, i - script_index);
    }
    lua_setglobal(L, "arg");
  }

#ifdef LUNET_EMBED_SCRIPTS
  if (lunet_runtime_run_embedded(runtime,
                                 lunet_embedded_scripts_gzip,
                                 lunet_embedded_scripts_gzip_len,
                                 argv[script_index],
                                 &exit_code,
                                 error,
                                 sizeof(error)) != 0) {
#else
  if (lunet_runtime_run_file(runtime,
                             argv[script_index],
                             &exit_code,
                             error,
                             sizeof(error)) != 0) {
#endif
    fprintf(stderr, "Error: %s\n", error);
    exit_code = 1;
  }

  lunet_runtime_shutdown(runtime);
  return exit_code;
}
