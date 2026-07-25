#include <stdio.h>
#include <string.h>

#include "lunet.h"

static int expect_failure(int rc, const char *error, const char *what) {
  if (rc == 0 || !error || error[0] == '\0') {
    fprintf(stderr, "expected failure for %s\n", what);
    return 1;
  }
  return 0;
}

int main(void) {
  lunet_runtime_t *runtime = NULL;
  lunet_runtime_t *duplicate = NULL;
  lunet_runtime_options_t options = {0};
  unsigned char malformed[] = {0x00, 0x01, 0x02};
  char error[512] = {0};
  int exit_code = -1;

  /* NULL-argument matrix: must fail cleanly, never crash. */
  if (lunet_runtime_init(NULL, &options, error, sizeof(error)) == 0) {
    fprintf(stderr, "expected failure for init(NULL out_runtime)\n");
    return 1;
  }
  lunet_runtime_shutdown(NULL); /* must be a harmless no-op */
  if (lunet_runtime_run_file(NULL, "test/sdk_api_script.lua", &exit_code, error,
                             sizeof(error)) == 0) {
    fprintf(stderr, "expected failure for run_file(NULL runtime)\n");
    return 1;
  }

  options.executable_path = "sdk-api-test";
  if (lunet_runtime_init(&runtime, &options, error, sizeof(error)) != 0) {
    fprintf(stderr, "init failed: %s\n", error);
    return 1;
  }
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_init(&duplicate, &options, error, sizeof(error)), error,
                     "duplicate init")) {
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  /* Invalid arguments must fail without consuming the runtime's one run. */
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_run_file(runtime, NULL, &exit_code, error, sizeof(error)),
                     error, "run_file(NULL path)")) {
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_run_embedded(runtime, NULL, 0, "main.lua", &exit_code,
                                                 error, sizeof(error)),
                     error, "run_embedded(NULL blob)")) {
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_run_embedded(runtime, malformed, sizeof(malformed), "",
                                                 &exit_code, error, sizeof(error)),
                     error, "run_embedded(empty entry)")) {
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_run_embedded(runtime, malformed, sizeof(malformed),
                                                 "/etc/passwd", &exit_code, error,
                                                 sizeof(error)),
                     error, "run_embedded(absolute entry)")) {
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_run_embedded(runtime, malformed, sizeof(malformed),
                                                 "../main.lua", &exit_code, error,
                                                 sizeof(error)), error, "unsafe entry")) {
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_run_embedded(runtime, malformed, sizeof(malformed),
                                                 "main.lua", &exit_code, error,
                                                 sizeof(error)), error, "malformed blob")) {
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  if (lunet_runtime_run_file(runtime, "test/sdk_api_script.lua", &exit_code, error,
                             sizeof(error)) != 0 || exit_code != 23) {
    fprintf(stderr, "file run failed: %s (exit %d)\n", error, exit_code);
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_run_file(runtime, "test/sdk_api_script.lua", &exit_code,
                                             error, sizeof(error)), error, "second run")) {
    lunet_runtime_shutdown(runtime);
    return 1;
  }
  lunet_runtime_shutdown(runtime);
  /* One runtime per process lifetime: init after shutdown must fail. */
  memset(error, 0, sizeof(error));
  if (expect_failure(lunet_runtime_init(&duplicate, &options, error, sizeof(error)), error,
                     "init after shutdown")) {
    return 1;
  }
  return 0;
}
