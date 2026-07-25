#include <stdio.h>

#include "lunet.h"
#include "lunet_embed_scripts_blob.h"

int main(int argc, char **argv) {
  lunet_runtime_options_t options = {0};
  lunet_runtime_t *runtime = NULL;
  char error[512] = {0};
  int exit_code = 1;

  options.executable_path = argc > 0 ? argv[0] : NULL;
  if (lunet_runtime_init(&runtime, &options, error, sizeof(error)) != 0 ||
      lunet_runtime_run_embedded(runtime,
                                 lunet_embedded_scripts_gzip,
                                 lunet_embedded_scripts_gzip_len,
                                 "main.lua",
                                 &exit_code,
                                 error,
                                 sizeof(error)) != 0) {
    fprintf(stderr, "lunet SDK example: %s\n", error);
    if (runtime) {
      lunet_runtime_shutdown(runtime);
    }
    return 1;
  }
  lunet_runtime_shutdown(runtime);
  return exit_code;
}
