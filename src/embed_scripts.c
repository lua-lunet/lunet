#include "embed_scripts.h"

#include <errno.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef LUNET_EMBED_SCRIPTS
#include <zlib.h>
#include "embed_scripts_blob.h"

#if defined(_WIN32)
#include <direct.h>
#include <windows.h>
#else
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define LUNET_EMBED_MAGIC "LUNETPK1"
#define LUNET_EMBED_MAGIC_LEN 8

static void lunet_embed_set_error(char *err, size_t err_len, const char *fmt, ...) {
  if (!err || err_len == 0 || !fmt) {
    return;
  }

  va_list ap;
  va_start(ap, fmt);
  vsnprintf(err, err_len, fmt, ap);
  va_end(ap);
}

static int lunet_embed_is_absolute_path(const char *path) {
  if (!path || path[0] == '\0') {
    return 0;
  }
#if defined(_WIN32)
  if ((path[0] == '\\' && path[1] == '\\') ||
      (path[0] != '\0' && path[1] == ':') ||
      path[0] == '/' || path[0] == '\\') {
    return 1;
  }
  return 0;
#else
  return path[0] == '/';
#endif
}

static int lunet_embed_is_safe_relative_path(const char *path) {
  const char *p = path;
  if (!path || path[0] == '\0') {
    return 0;
  }
  if (lunet_embed_is_absolute_path(path)) {
    return 0;
  }

  while (*p != '\0') {
    const char *seg;
    const char *end;
    size_t len;

    while (*p == '/' || *p == '\\') {
      p++;
    }
    if (*p == '\0') {
      break;
    }

    seg = p;
    while (*p != '\0' && *p != '/' && *p != '\\') {
      p++;
    }
    end = p;
    len = (size_t)(end - seg);

    if (len == 0) {
      continue;
    }
    if (len == 2 && seg[0] == '.' && seg[1] == '.') {
      return 0;
    }
#if defined(_WIN32)
    for (size_t i = 0; i < len; i++) {
      if (seg[i] == ':') {
        return 0;
      }
    }
#endif
  }

  return 1;
}

static int lunet_embed_join_path(const char *base,
                                 const char *relative,
                                 char *out,
                                 size_t out_len) {
  size_t base_len;
  size_t rel_len;
  size_t need;
  size_t pos;

  if (!base || !relative || !out || out_len == 0) {
    return -1;
  }

  base_len = strlen(base);
  rel_len = strlen(relative);
  need = base_len + 1 + rel_len + 1;
  if (need > out_len) {
    return -1;
  }

  memcpy(out, base, base_len);
  pos = base_len;
  if (pos > 0 && out[pos - 1] != '/' && out[pos - 1] != '\\') {
#if defined(_WIN32)
    out[pos++] = '\\';
#else
    out[pos++] = '/';
#endif
  }

  for (size_t i = 0; i < rel_len; i++) {
    char c = relative[i];
    if (c == '/' || c == '\\') {
#if defined(_WIN32)
      out[pos++] = '\\';
#else
      out[pos++] = '/';
#endif
    } else {
      out[pos++] = c;
    }
  }
  out[pos] = '\0';
  return 0;
}

static int lunet_embed_dir_exists(const char *path) {
#if defined(_WIN32)
  DWORD attr = GetFileAttributesA(path);
  return attr != INVALID_FILE_ATTRIBUTES &&
         (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
#else
  struct stat st;
  return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
#endif
}

static int lunet_embed_file_exists(const char *path) {
#if defined(_WIN32)
  DWORD attr = GetFileAttributesA(path);
  return attr != INVALID_FILE_ATTRIBUTES &&
         (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
#else
  struct stat st;
  return stat(path, &st) == 0 && S_ISREG(st.st_mode);
#endif
}

static int lunet_embed_mkdir_single(const char *path) {
#if defined(_WIN32)
  if (_mkdir(path) == 0 || errno == EEXIST) {
    return 0;
  }
  return -1;
#else
  if (mkdir(path, 0700) == 0 || errno == EEXIST) {
    return 0;
  }
  return -1;
#endif
}

static int lunet_embed_ensure_parent_dirs(const char *path, char *err, size_t err_len) {
  char tmp[PATH_MAX];
  size_t len;

  if (!path) {
    lunet_embed_set_error(err, err_len, "invalid path");
    return -1;
  }

  len = strlen(path);
  if (len >= sizeof(tmp)) {
    lunet_embed_set_error(err, err_len, "path too long");
    return -1;
  }
  memcpy(tmp, path, len + 1);

  for (size_t i = 0; i < len; i++) {
    if (tmp[i] == '/' || tmp[i] == '\\') {
      char saved = tmp[i];
      tmp[i] = '\0';

      if (tmp[0] != '\0') {
#if defined(_WIN32)
        if (!(i == 2 && tmp[1] == ':')) {
          if (!lunet_embed_dir_exists(tmp) && lunet_embed_mkdir_single(tmp) != 0) {
            lunet_embed_set_error(err, err_len, "mkdir failed for '%s': %s", tmp, strerror(errno));
            return -1;
          }
        }
#else
        if (!lunet_embed_dir_exists(tmp) && lunet_embed_mkdir_single(tmp) != 0) {
          lunet_embed_set_error(err, err_len, "mkdir failed for '%s': %s", tmp, strerror(errno));
          return -1;
        }
#endif
      }
      tmp[i] = saved;
    }
  }

  return 0;
}

static unsigned int lunet_embed_read_u32_le(const unsigned char *p) {
  return ((unsigned int)p[0]) |
         ((unsigned int)p[1] << 8) |
         ((unsigned int)p[2] << 16) |
         ((unsigned int)p[3] << 24);
}

static unsigned long long lunet_embed_read_u64_le(const unsigned char *p) {
  return ((unsigned long long)p[0]) |
         ((unsigned long long)p[1] << 8) |
         ((unsigned long long)p[2] << 16) |
         ((unsigned long long)p[3] << 24) |
         ((unsigned long long)p[4] << 32) |
         ((unsigned long long)p[5] << 40) |
         ((unsigned long long)p[6] << 48) |
         ((unsigned long long)p[7] << 56);
}

static int lunet_embed_decompress_gzip(const unsigned char *in_data,
                                       size_t in_len,
                                       unsigned char **out_data,
                                       size_t *out_len,
                                       char *err,
                                       size_t err_len) {
  z_stream zs;
  unsigned char *buffer = NULL;
  size_t capacity;
  size_t used = 0;
  int rc;

  if (!in_data || in_len == 0 || !out_data || !out_len) {
    lunet_embed_set_error(err, err_len, "invalid gzip input");
    return -1;
  }

  memset(&zs, 0, sizeof(zs));
  rc = inflateInit2(&zs, 16 + MAX_WBITS);
  if (rc != Z_OK) {
    lunet_embed_set_error(err, err_len, "inflateInit2 failed: %d", rc);
    return -1;
  }

  capacity = in_len * 4;
  if (capacity < 65536) {
    capacity = 65536;
  }
  buffer = (unsigned char *)malloc(capacity);
  if (!buffer) {
    inflateEnd(&zs);
    lunet_embed_set_error(err, err_len, "out of memory");
    return -1;
  }

  zs.next_in = (Bytef *)in_data;
  zs.avail_in = (uInt)in_len;

  for (;;) {
    if (used == capacity) {
      unsigned char *grown;
      size_t next = capacity * 2;
      if (next <= capacity) {
        free(buffer);
        inflateEnd(&zs);
        lunet_embed_set_error(err, err_len, "decompressed data too large");
        return -1;
      }
      grown = (unsigned char *)realloc(buffer, next);
      if (!grown) {
        free(buffer);
        inflateEnd(&zs);
        lunet_embed_set_error(err, err_len, "out of memory");
        return -1;
      }
      buffer = grown;
      capacity = next;
    }

    zs.next_out = buffer + used;
    zs.avail_out = (uInt)(capacity - used);
    rc = inflate(&zs, Z_NO_FLUSH);
    used = capacity - zs.avail_out;

    if (rc == Z_STREAM_END) {
      break;
    }
    if (rc == Z_OK) {
      if (zs.avail_out == 0) {
        continue;
      }
      if (zs.avail_in == 0) {
        free(buffer);
        inflateEnd(&zs);
        lunet_embed_set_error(err, err_len, "truncated gzip payload");
        return -1;
      }
      continue;
    }
    if (rc == Z_BUF_ERROR && zs.avail_out == 0) {
      continue;
    }

    free(buffer);
    inflateEnd(&zs);
    lunet_embed_set_error(err, err_len, "inflate failed: %d", rc);
    return -1;
  }

  inflateEnd(&zs);
  *out_data = buffer;
  *out_len = used;
  return 0;
}

static int lunet_embed_write_file(const char *path,
                                  const unsigned char *data,
                                  size_t len,
                                  char *err,
                                  size_t err_len) {
  FILE *f = fopen(path, "wb");
  if (!f) {
    lunet_embed_set_error(err, err_len, "failed to open '%s': %s", path, strerror(errno));
    return -1;
  }

  if (len > 0 && fwrite(data, 1, len, f) != len) {
    fclose(f);
    lunet_embed_set_error(err, err_len, "failed to write '%s': %s", path, strerror(errno));
    return -1;
  }

  if (fclose(f) != 0) {
    lunet_embed_set_error(err, err_len, "failed to close '%s': %s", path, strerror(errno));
    return -1;
  }

#if !defined(_WIN32)
  chmod(path, 0600);
#endif
  return 0;
}

static int lunet_embed_extract_payload(const unsigned char *payload,
                                       size_t payload_len,
                                       const char *target_dir,
                                       char *err,
                                       size_t err_len) {
  size_t off = 0;
  unsigned int file_count;

  if (!payload || payload_len < (LUNET_EMBED_MAGIC_LEN + 4)) {
    lunet_embed_set_error(err, err_len, "embedded payload is too small");
    return -1;
  }
  if (memcmp(payload, LUNET_EMBED_MAGIC, LUNET_EMBED_MAGIC_LEN) != 0) {
    lunet_embed_set_error(err, err_len, "invalid embedded payload header");
    return -1;
  }

  off += LUNET_EMBED_MAGIC_LEN;
  file_count = lunet_embed_read_u32_le(payload + off);
  off += 4;

  for (unsigned int i = 0; i < file_count; i++) {
    unsigned int rel_len;
    unsigned long long file_len_u64;
    size_t file_len;
    char *rel = NULL;
    char fullpath[PATH_MAX];

    if (off + 12 > payload_len) {
      lunet_embed_set_error(err, err_len, "truncated entry header");
      return -1;
    }

    rel_len = lunet_embed_read_u32_le(payload + off);
    off += 4;
    file_len_u64 = lunet_embed_read_u64_le(payload + off);
    off += 8;

    if (rel_len == 0 || rel_len >= PATH_MAX) {
      lunet_embed_set_error(err, err_len, "invalid embedded path length");
      return -1;
    }
    if (off + rel_len > payload_len) {
      lunet_embed_set_error(err, err_len, "truncated embedded path");
      return -1;
    }
    if (file_len_u64 > (unsigned long long)(payload_len - off - rel_len)) {
      lunet_embed_set_error(err, err_len, "truncated embedded file data");
      return -1;
    }

    rel = (char *)malloc((size_t)rel_len + 1);
    if (!rel) {
      lunet_embed_set_error(err, err_len, "out of memory");
      return -1;
    }
    memcpy(rel, payload + off, rel_len);
    rel[rel_len] = '\0';
    off += rel_len;

    for (unsigned int j = 0; j < rel_len; j++) {
      if (rel[j] == '\0') {
        free(rel);
        lunet_embed_set_error(err, err_len, "invalid embedded path");
        return -1;
      }
    }

    if (!lunet_embed_is_safe_relative_path(rel)) {
      lunet_embed_set_error(err, err_len, "unsafe embedded path '%s'", rel);
      free(rel);
      return -1;
    }
    if (lunet_embed_join_path(target_dir, rel, fullpath, sizeof(fullpath)) != 0) {
      free(rel);
      lunet_embed_set_error(err, err_len, "output path too long for '%s'", rel);
      return -1;
    }
    if (lunet_embed_ensure_parent_dirs(fullpath, err, err_len) != 0) {
      free(rel);
      return -1;
    }

    if (file_len_u64 > (unsigned long long)SIZE_MAX) {
      free(rel);
      lunet_embed_set_error(err, err_len, "embedded file too large");
      return -1;
    }
    file_len = (size_t)file_len_u64;
    if (lunet_embed_write_file(fullpath, payload + off, file_len, err, err_len) != 0) {
      free(rel);
      return -1;
    }
    off += file_len;
    free(rel);
  }

  if (off != payload_len) {
    lunet_embed_set_error(err, err_len, "unexpected trailing data in embedded payload");
    return -1;
  }

  return 0;
}

static int lunet_embed_prepend_package_field(lua_State *L,
                                             const char *field,
                                             const char *prefix,
                                             char *err,
                                             size_t err_len) {
  const char *old_value = NULL;
  size_t old_len = 0;
  size_t prefix_len;
  size_t out_len;
  char *out_value;

  lua_getglobal(L, "package");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lunet_embed_set_error(err, err_len, "lua package table not found");
    return -1;
  }

  lua_getfield(L, -1, field);
  old_value = lua_tostring(L, -1);
  old_len = old_value ? strlen(old_value) : 0;
  prefix_len = strlen(prefix);
  out_len = prefix_len + (old_len ? old_len + 1 : 0) + 1;

  out_value = (char *)malloc(out_len);
  if (!out_value) {
    lua_pop(L, 2);
    lunet_embed_set_error(err, err_len, "out of memory");
    return -1;
  }

  if (old_len > 0) {
    snprintf(out_value, out_len, "%s;%s", prefix, old_value);
  } else {
    snprintf(out_value, out_len, "%s", prefix);
  }

  lua_pop(L, 1);
  lua_pushstring(L, out_value);
  lua_setfield(L, -2, field);
  lua_pop(L, 1);
  free(out_value);
  return 0;
}

static int lunet_embed_patch_package_paths(lua_State *L,
                                           const char *embed_dir,
                                           char *err,
                                           size_t err_len) {
  size_t dir_len = strlen(embed_dir);
  size_t path_len = dir_len * 2 + 32;
  char *path_prefix = (char *)malloc(path_len);
  if (!path_prefix) {
    lunet_embed_set_error(err, err_len, "out of memory");
    return -1;
  }

#if defined(_WIN32)
  snprintf(path_prefix, path_len, "%s\\?.lua;%s\\?\\init.lua", embed_dir, embed_dir);
#else
  snprintf(path_prefix, path_len, "%s/?.lua;%s/?/init.lua", embed_dir, embed_dir);
#endif

  if (lunet_embed_prepend_package_field(L, "path", path_prefix, err, err_len) != 0) {
    free(path_prefix);
    return -1;
  }
  free(path_prefix);

#if defined(_WIN32)
  {
    size_t cpath_len = dir_len * 3 + 40;
    char *cpath_prefix = (char *)malloc(cpath_len);
    if (!cpath_prefix) {
      lunet_embed_set_error(err, err_len, "out of memory");
      return -1;
    }
    snprintf(cpath_prefix, cpath_len, "%s\\?.dll;%s\\?\\init.dll;%s\\lunet\\?.dll",
             embed_dir, embed_dir, embed_dir);
    if (lunet_embed_prepend_package_field(L, "cpath", cpath_prefix, err, err_len) != 0) {
      free(cpath_prefix);
      return -1;
    }
    free(cpath_prefix);
  }
#else
  {
    size_t cpath_len = dir_len * 3 + 31;
    char *cpath_prefix = (char *)malloc(cpath_len);
    if (!cpath_prefix) {
      lunet_embed_set_error(err, err_len, "out of memory");
      return -1;
    }
    snprintf(cpath_prefix, cpath_len, "%s/?.so;%s/?/init.so;%s/lunet/?.so",
             embed_dir, embed_dir, embed_dir);
    if (lunet_embed_prepend_package_field(L, "cpath", cpath_prefix, err, err_len) != 0) {
      free(cpath_prefix);
      return -1;
    }
    free(cpath_prefix);
  }
#endif

  return 0;
}

#if defined(_WIN32)
static int lunet_embed_make_temp_dir(char *out_dir, size_t out_len, char *err, size_t err_len) {
  char base[MAX_PATH];
  char unique[MAX_PATH];
  DWORD rc = GetTempPathA((DWORD)sizeof(base), base);
  if (rc == 0 || rc >= sizeof(base)) {
    lunet_embed_set_error(err, err_len, "GetTempPath failed");
    return -1;
  }
  if (GetTempFileNameA(base, "lnt", 0, unique) == 0) {
    lunet_embed_set_error(err, err_len, "GetTempFileName failed");
    return -1;
  }
  DeleteFileA(unique);
  if (!CreateDirectoryA(unique, NULL)) {
    lunet_embed_set_error(err, err_len, "CreateDirectory failed");
    return -1;
  }

  if (strlen(unique) + 1 > out_len) {
    lunet_embed_set_error(err, err_len, "temp dir path too long");
    return -1;
  }
  strcpy(out_dir, unique);
  return 0;
}
#else
static int lunet_embed_pick_temp_base(char *base, size_t base_len) {
#if defined(__linux__)
  struct stat st;
  if (stat("/dev/shm", &st) == 0 && S_ISDIR(st.st_mode)) {
    snprintf(base, base_len, "/dev/shm");
    return 0;
  }
#endif
#if defined(__APPLE__)
  {
    size_t need = confstr(_CS_DARWIN_USER_TEMP_DIR, NULL, 0);
    if (need > 0 && need < base_len) {
      confstr(_CS_DARWIN_USER_TEMP_DIR, base, base_len);
      if (need > 1 && base[need - 2] == '/') {
        base[need - 2] = '\0';
      }
      return 0;
    }
  }
#endif
  snprintf(base, base_len, "/tmp");
  return 0;
}

static int lunet_embed_make_temp_dir(char *out_dir, size_t out_len, char *err, size_t err_len) {
  char base[PATH_MAX];
  char templ[PATH_MAX];
  char *created;

  lunet_embed_pick_temp_base(base, sizeof(base));
  if (snprintf(templ, sizeof(templ), "%s/lunet-XXXXXX", base) >= (int)sizeof(templ)) {
    lunet_embed_set_error(err, err_len, "temp dir template too long");
    return -1;
  }

  created = mkdtemp(templ);
  if (!created) {
    lunet_embed_set_error(err, err_len, "mkdtemp failed: %s", strerror(errno));
    return -1;
  }

  chmod(created, 0700);
  if (strlen(created) + 1 > out_len) {
    lunet_embed_set_error(err, err_len, "temp dir path too long");
    return -1;
  }
  strcpy(out_dir, created);
  return 0;
}
#endif
#endif /* LUNET_EMBED_SCRIPTS */

int lunet_embed_scripts_prepare(lua_State *L,
                                char *out_dir,
                                size_t out_dir_len,
                                char *err,
                                size_t err_len) {
#ifdef LUNET_EMBED_SCRIPTS
  unsigned char *payload = NULL;
  size_t payload_len = 0;

  if (!L || !out_dir || out_dir_len == 0) {
    lunet_embed_set_error(err, err_len, "invalid arguments");
    return -1;
  }

  if (lunet_embedded_scripts_gzip_len == 0) {
    lunet_embed_set_error(err, err_len, "embedded script blob is empty");
    return -1;
  }

  if (lunet_embed_make_temp_dir(out_dir, out_dir_len, err, err_len) != 0) {
    return -1;
  }
  if (lunet_embed_decompress_gzip(lunet_embedded_scripts_gzip,
                                  lunet_embedded_scripts_gzip_len,
                                  &payload,
                                  &payload_len,
                                  err,
                                  err_len) != 0) {
    return -1;
  }
  if (lunet_embed_extract_payload(payload, payload_len, out_dir, err, err_len) != 0) {
    free(payload);
    return -1;
  }
  free(payload);

  if (lunet_embed_patch_package_paths(L, out_dir, err, err_len) != 0) {
    return -1;
  }
  return 0;
#else
  (void)L;
  (void)out_dir;
  (void)out_dir_len;
  (void)err;
  (void)err_len;
  return 0;
#endif
}

int lunet_embed_scripts_resolve_script(const char *embed_dir,
                                       const char *script_arg,
                                       char *out_script,
                                       size_t out_script_len,
                                       char *err,
                                       size_t err_len) {
#ifdef LUNET_EMBED_SCRIPTS
  if (!embed_dir || !script_arg || !out_script || out_script_len == 0) {
    lunet_embed_set_error(err, err_len, "invalid arguments");
    return -1;
  }
  if (lunet_embed_is_absolute_path(script_arg)) {
    return 0;
  }
  if (!lunet_embed_is_safe_relative_path(script_arg)) {
    lunet_embed_set_error(err, err_len, "unsafe script path '%s'", script_arg);
    return -1;
  }
  if (lunet_embed_join_path(embed_dir, script_arg, out_script, out_script_len) != 0) {
    lunet_embed_set_error(err, err_len, "resolved script path too long");
    return -1;
  }
  if (!lunet_embed_file_exists(out_script)) {
    return 0;
  }
  return 1;
#else
  (void)embed_dir;
  (void)script_arg;
  (void)out_script;
  (void)out_script_len;
  (void)err;
  (void)err_len;
  return 0;
#endif
}
