# Binary Release Layout

Each release publishes a platform-specific binary archive alongside the SDK:

- `lunet-linux-amd64.tar.gz`
- `lunet-linux-arm64.tar.gz`
- `lunet-macos.tar.gz`
- `lunet-windows-amd64.zip`

This archive is a self-contained deployment: extract it anywhere and run
`lunet-run` directly. No other installation steps are needed.

## Archive layout

```text
lunet-run                           # standalone executable (lunet-run.exe on Windows)
lunet.so                            # core shared library for require("lunet")
                                    #   (lunet.dll on Windows)
lunet/                              # extension modules
  sqlite3.so / postgres.so          # DB driver shared libraries
  mysql.so                          #   (.dll on Windows)
  sqlite3_tx.lua / postgres_tx.lua  # DB transaction wrappers
  mysql_tx.lua
  liblnt_shared.so                  # lnt_shared shared dictionary (Linux)
  liblnt_shared.dylib               #   (macOS — not shipped on Windows)
  lnt_shared.lua                    # lnt_shared Lua FFI loader
  liblunet_jsonic.so                # jsonic streaming JSON decoder (Linux)
  liblunet_jsonic.dylib             #   (macOS — not shipped on Windows)
  jsonic.lua                        # jsonic Lua FFI loader + encoder
  dkjson-encode-v2.10.lua           # ordered-JSON encoder (used by jsonic)
```

## How extensions are loaded

`lunet-run` automatically adds `<executable_dir>/lunet/?.lua` to `package.path`
and `<executable_dir>/lunet/?.so` to `package.cpath` at startup (with correct
platform suffixes). This means the following work from any working directory
as long as the archive directory tree is preserved:

```lua
local cache = require("lunet.lnt_shared")
local json  = require("lunet.jsonic")
```

Each Lua loader (`lnt_shared.lua`, `jsonic.lua`) resolves its compiled library
relative to its own directory, so no manual configuration is required.

If you move the `.so`/`.dylib` files elsewhere, set the environment variable
that the corresponding loader checks:

| Extension  | Environment variable         |
|------------|------------------------------|
| lnt_shared | `LUNET_LNT_SHARED_LIB`       |
| jsonic     | `LUNET_JSONIC_LIB`           |

## Using extensions standalone (without lunet-run)

Both Rust extensions export a stable C ABI and can be loaded directly by any
LuaJIT program via `ffi.load()`. The sections below document the complete FFI
API surface — cdef declarations, error codes, and value type constants.

No header files are needed: the declarations below are written in LuaJIT FFI
cdef syntax and can be pasted directly into a `ffi.cdef[[...]]` block.

---

## lnt_shared — shared dictionary

POSIX-only (Linux / macOS). Provides an in-memory key-value store backed by
`mmap(MAP_SHARED|MAP_ANONYMOUS)` with TTL-based expiry.

### FFI declarations

```lua
ffi.cdef[[
  /* Opaque dictionary handle */
  typedef void* ngx_shared_handle_t;

  /* Lifecycle */
  ngx_shared_handle_t ngx_shared_open(const char* name, uint64_t size_bytes);
  void                ngx_shared_close(ngx_shared_handle_t h);

  /* CRUD */
  int  ngx_shared_get(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      uint8_t** out_val, size_t* out_len, int* out_type);
  void ngx_shared_free_bytes(uint8_t* p, size_t len);

  int  ngx_shared_set(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      const uint8_t* val, size_t vlen,
                      int val_type, double ttl_secs);
  int  ngx_shared_add(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      const uint8_t* val, size_t vlen,
                      int val_type, double ttl_secs);
  int  ngx_shared_replace(ngx_shared_handle_t h,
                          const uint8_t* key, size_t klen,
                          const uint8_t* val, size_t vlen,
                          int val_type, double ttl_secs);
  int  ngx_shared_delete(ngx_shared_handle_t h,
                         const uint8_t* key, size_t klen);

  /* Numeric increment */
  int  ngx_shared_incr(ngx_shared_handle_t h,
                       const uint8_t* key, size_t klen,
                       double delta, double init, int has_init,
                       double ttl_secs, double* result);

  /* TTL management */
  int  ngx_shared_expire(ngx_shared_handle_t h,
                         const uint8_t* key, size_t klen,
                         double ttl_secs);
  int  ngx_shared_ttl(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      double* out_ttl);

  /* Bulk operations */
  void ngx_shared_flush_all(ngx_shared_handle_t h);
  int  ngx_shared_flush_expired(ngx_shared_handle_t h, int max);

  /* Stats */
  uint64_t ngx_shared_capacity(ngx_shared_handle_t h);
  uint64_t ngx_shared_free_space(ngx_shared_handle_t h);
]]
```

### Error codes

| Code | Constant                | Meaning               |
|------|-------------------------|-----------------------|
| `0`  | `NGX_SHARED_OK`         | Success               |
| `-1` | `NGX_SHARED_NOT_FOUND`  | Key not found         |
| `-2` | `NGX_SHARED_ERR_EXISTS` | Key already exists    |
| `-3` | `NGX_SHARED_ERR_NOMEM`  | Out of memory         |
| `-4` | `NGX_SHARED_ERR_TYPE`   | Value type mismatch   |
| `-5` | `NGX_SHARED_ERR_FULL`   | Hash table full       |
| `-6` | `NGX_SHARED_ERR_INVAL`  | Invalid argument      |

### Value types

| Constant | Value | Storage format              |
|----------|-------|-----------------------------|
| bytes    | `0`   | Raw bytes                   |
| f64      | `1`   | IEEE 754 double, LE         |
| bool     | `2`   | Single byte (0 or 1)        |

### Memory ownership

`ngx_shared_get` heap-allocates a buffer for the returned value. The caller
**must** free it with `ngx_shared_free_bytes(ptr, len)`. The Lua wrapper in
`lnt_shared.lua` handles this automatically; standalone FFI users must call
`free_bytes` themselves.

### Symbol naming

FFI symbols use the `ngx_shared_*` prefix (rather than `lnt_shared_*`). This
is a legacy name retained for ABI compatibility after the rename from
`ngx_shared` to `lnt_shared` in v0.4.3. The symbols are stable and will not
change.

### Minimal example (standalone FFI)

```lua
local ffi = require("ffi")
ffi.cdef[[ /* paste cdef block above */ ]]
local lib = ffi.load("./lunet/liblnt_shared.so")  -- or .dylib on macOS

local h = lib.ngx_shared_open("my_dict", 65536)
assert(h ~= nil)

-- Set a string value
local rc = lib.ngx_shared_set(h, "greeting", 8, "hello", 5, 0, 0)
assert(rc == 0)

-- Get it back
local out_val = ffi.new("uint8_t*[1]")
local out_len = ffi.new("size_t[1]")
local out_type = ffi.new("int[1]")
rc = lib.ngx_shared_get(h, "greeting", 8, out_val, out_len, out_type)
assert(rc == 0)
print(ffi.string(out_val[0], out_len[0]))  --> "hello"
lib.ngx_shared_free_bytes(out_val[0], out_len[0])

lib.ngx_shared_close(h)
```

---

## jsonic — streaming JSON codec

POSIX-only (Linux / macOS). Provides a streaming JSON decoder (with an
Lua-side encoder).

### FFI declarations

```lua
ffi.cdef[[
  int  lunet_jsonic_decode(const uint8_t* json, size_t len,
                           uint8_t** out, size_t* out_len);
  void lunet_jsonic_free_bytes(uint8_t* p, size_t len);
]]
```

### Error codes

| Code | Constant              | Meaning           |
|------|-----------------------|-------------------|
| `0`  | `JSONIC_OK`           | Success           |
| `-1` | `JSONIC_ERR_PARSE`    | Parse error       |
| `-2` | `JSONIC_ERR_INVAL`    | Invalid argument  |

### Binary wire format

`lunet_jsonic_decode` returns a binary encoding (not JSON text). The Lua
loader in `jsonic.lua` decodes this into Lua tables. Standalone FFI users
who want decoded Lua values should use the Lua wrapper rather than calling
the FFI directly — the binary format is internal to the codec pair.

### Memory ownership

Same as lnt_shared: `lunet_jsonic_decode` heap-allocates the output buffer;
the caller must free it with `lunet_jsonic_free_bytes`.

---

## Database drivers

The `.so`/`.dll` files in `lunet/` are loaded automatically by `require()`
when the corresponding Lua module is first accessed. Transaction wrappers
(`*_tx.lua`) are plain Lua modules that add `conn:begin()`, `conn:commit()`,
and `conn:rollback()` methods to the native driver connections.

---

## Platform notes

- **Linux (amd64 / arm64)**: All extensions are included. The archive is
  built on Ubuntu 24.04 and links against system `glibc` and `openssl`.
- **macOS (arm64)**: All extensions are included. The archive is built on
  macOS 15+ and targets `macosx-version-min=14.0`.
- **Windows (amd64)**: Rust extensions (`lnt_shared`, `jsonic`) are not
  included because the underlying crates are POSIX-only. Database drivers
  and transaction wrappers are shipped.
