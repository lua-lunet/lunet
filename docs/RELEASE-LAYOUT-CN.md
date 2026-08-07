# 二进制发布包布局

每个发布版本都会与 SDK 一同发布按平台区分的二进制压缩包：

- `lunet-linux-amd64.tar.gz`
- `lunet-linux-arm64.tar.gz`
- `lunet-macos.tar.gz`
- `lunet-windows-amd64.zip`

这是一个自包含的部署包：解压到任意目录后直接运行 `lunet-run` 即可，无需其他
安装步骤。

## 压缩包布局

```text
lunet-run                           # 独立可执行文件（Windows 上为 lunet-run.exe）
lunet.so                            # 核心动态库，用于 require("lunet")
                                    #   （Windows 上为 lunet.dll）
lunet/                              # 扩展模块
  sqlite3.so / postgres.so          # 数据库驱动动态库
  mysql.so                          #   （Windows 上为 .dll）
  sqlite3_tx.lua / postgres_tx.lua  # 数据库事务封装
  mysql_tx.lua
  liblnt_shared.so                  # lnt_shared 共享字典（Linux）
  liblnt_shared.dylib               #   （macOS，Windows 不提供）
  lnt_shared.lua                    # lnt_shared Lua FFI 加载器
  liblunet_jsonic.so                # jsonic 流式 JSON 解码器（Linux）
  liblunet_jsonic.dylib             #   （macOS，Windows 不提供）
  jsonic.lua                        # jsonic Lua FFI 加载器 + 编码器
  dkjson-encode-v2.10.lua           # 有序 JSON 编码器（jsonic 依赖）
docs/                               # 用户文档（见下文）
  HTTPC.md / HTTPC-CN.md
  PHILOSOPHY.md / PHILOSOPHY-CN.md
  SECURITY_ARCHITECTURE.md / SECURITY_ARCHITECTURE-CN.md
  TYPE_OVERRIDES.md / TYPE_OVERRIDES-CN.md
```

## 压缩包中的文档

压缩包自带文档，这样使用二进制发布版、手中没有源码检出的用户，
不必回到仓库去查阅 API。

打包策略是**默认包含、按名排除**：每个 `docs/*.md` 都会被复制到压缩包的
`docs/` 目录，除非其文件名出现在 `docs/.dist-exclude` 中。因此新增一篇面向
用户的文档无需改动发布流程，只有刻意的排除才需要。

目前排除的是从源码构建与嵌入指南、贡献者工作流、徽章指南，以及一份内部工程
报告——这些对使用预编译二进制的用户都不适用。`RELEASE-LAYOUT.md` 之所以被排除
在 `docs/` 之外，仅仅是因为它改为放在压缩包根目录。

由于这些文件会随发布一同分发，它们属于发布内容的一部分：参见 `AGENTS.md` 中的
发布质量门禁，其中要求在推送版本标签前先审阅文档。

## 扩展加载机制

`lunet-run` 启动时会自动将 `<可执行文件目录>/lunet/?.lua` 加入 `package.path`，
并将 `<可执行文件目录>/lunet/?.so` 加入 `package.cpath`（使用正确的平台后缀）。
这意味着只要保持压缩包的目录结构不变，以下代码可以从任意工作目录正常运行：

```lua
local cache = require("lunet.lnt_shared")
local json  = require("lunet.jsonic")
```

每个 Lua 加载器（`lnt_shared.lua`、`jsonic.lua`）会相对于自身所在目录解析
编译后的库文件，因此无需手动配置。

如果将 `.so`/`.dylib` 文件移动到其他位置，请设置对应加载器检查的环境变量：

| 扩展       | 环境变量                     |
|------------|------------------------------|
| lnt_shared | `LUNET_LNT_SHARED_LIB`       |
| jsonic     | `LUNET_JSONIC_LIB`           |

## 独立使用扩展（不依赖 lunet-run）

两个 Rust 扩展都导出了稳定的 C ABI，任何 LuaJIT 程序都可以通过 `ffi.load()`
直接加载。以下章节记录了完整的 FFI API 接口——cdef 声明、错误码和值类型常量。

无需头文件：以下声明使用 LuaJIT FFI cdef 语法编写，可以直接粘贴到
`ffi.cdef[[...]]` 块中使用。

---

## lnt_shared — 共享字典

仅限 POSIX 平台（Linux / macOS）。基于 `mmap(MAP_SHARED|MAP_ANONYMOUS)` 的
内存键值存储，支持 TTL 过期机制。

### FFI 声明

```lua
ffi.cdef[[
  /* 不透明字典句柄 */
  typedef void* ngx_shared_handle_t;

  /* 生命周期 */
  ngx_shared_handle_t ngx_shared_open(const char* name, uint64_t size_bytes);
  void                ngx_shared_close(ngx_shared_handle_t h);

  /* CRUD 操作 */
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

  /* 数值递增 */
  int  ngx_shared_incr(ngx_shared_handle_t h,
                       const uint8_t* key, size_t klen,
                       double delta, double init, int has_init,
                       double ttl_secs, double* result);

  /* TTL 管理 */
  int  ngx_shared_expire(ngx_shared_handle_t h,
                         const uint8_t* key, size_t klen,
                         double ttl_secs);
  int  ngx_shared_ttl(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      double* out_ttl);

  /* 批量操作 */
  void ngx_shared_flush_all(ngx_shared_handle_t h);
  int  ngx_shared_flush_expired(ngx_shared_handle_t h, int max);

  /* 统计 */
  uint64_t ngx_shared_capacity(ngx_shared_handle_t h);
  uint64_t ngx_shared_free_space(ngx_shared_handle_t h);
]]
```

### 错误码

| 代码  | 常量                     | 含义               |
|-------|--------------------------|---------------------|
| `0`   | `NGX_SHARED_OK`          | 成功               |
| `-1`  | `NGX_SHARED_NOT_FOUND`   | 键不存在           |
| `-2`  | `NGX_SHARED_ERR_EXISTS`  | 键已存在           |
| `-3`  | `NGX_SHARED_ERR_NOMEM`   | 内存不足           |
| `-4`  | `NGX_SHARED_ERR_TYPE`    | 值类型不匹配       |
| `-5`  | `NGX_SHARED_ERR_FULL`    | 哈希表已满         |
| `-6`  | `NGX_SHARED_ERR_INVAL`   | 参数无效           |

### 值类型

| 常量    | 值   | 存储格式                  |
|---------|------|---------------------------|
| bytes   | `0`  | 原始字节                  |
| f64     | `1`  | IEEE 754 双精度，小端序   |
| bool    | `2`  | 单字节（0 或 1）          |

### 内存所有权

`ngx_shared_get` 会在堆上分配一个缓冲区来存放返回值。调用者**必须**使用
`ngx_shared_free_bytes(ptr, len)` 释放该缓冲区。`lnt_shared.lua` 中的 Lua
封装层会自动处理释放；独立 FFI 用户需要自行调用 `free_bytes`。

### 符号命名

FFI 符号使用 `ngx_shared_*` 前缀（而非 `lnt_shared_*`）。这是从 `ngx_shared`
重命名为 `lnt_shared`（v0.4.3）后保留的旧名，用于保持 ABI 兼容性。这些符号
是稳定的，不会变更。

### 最小示例（独立 FFI）

```lua
local ffi = require("ffi")
ffi.cdef[[ /* 粘贴上方 cdef 块 */ ]]
local lib = ffi.load("./lunet/liblnt_shared.so")  -- macOS 上为 .dylib

local h = lib.ngx_shared_open("my_dict", 65536)
assert(h ~= nil)

-- 设置一个字符串值
local rc = lib.ngx_shared_set(h, "greeting", 8, "hello", 5, 0, 0)
assert(rc == 0)

-- 读取回来
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

## jsonic — 流式 JSON 编解码器

仅限 POSIX 平台（Linux / macOS）。提供流式 JSON 解码器（搭配 Lua 端编码器）。

### FFI 声明

```lua
ffi.cdef[[
  int  lunet_jsonic_decode(const uint8_t* json, size_t len,
                           uint8_t** out, size_t* out_len);
  void lunet_jsonic_free_bytes(uint8_t* p, size_t len);
]]
```

### 错误码

| 代码  | 常量               | 含义           |
|-------|--------------------|----------------|
| `0`   | `JSONIC_OK`        | 成功           |
| `-1`  | `JSONIC_ERR_PARSE` | 解析错误       |
| `-2`  | `JSONIC_ERR_INVAL` | 参数无效       |

### 二进制传输格式

`lunet_jsonic_decode` 返回的是二进制编码（非 JSON 文本）。`jsonic.lua` 中的
Lua 加载器会将其解码为 Lua 表。需要解码后的 Lua 值的独立 FFI 用户应使用
Lua 封装层，而不是直接调用 FFI——二进制格式属于编解码器内部实现。

### 内存所有权

与 lnt_shared 相同：`lunet_jsonic_decode` 在堆上分配输出缓冲区，调用者必须
使用 `lunet_jsonic_free_bytes` 释放。

---

## 数据库驱动

`lunet/` 目录下的 `.so`/`.dll` 文件会在首次访问对应 Lua 模块时由 `require()`
自动加载。事务封装（`*_tx.lua`）是纯 Lua 模块，为原生驱动连接添加了
`conn:begin()`、`conn:commit()` 和 `conn:rollback()` 方法。

---

## 平台说明

- **Linux (amd64 / arm64)**：包含所有扩展。在 Ubuntu 24.04 上构建，链接系统
  `glibc` 和 `openssl`。
- **macOS (arm64)**：包含所有扩展。在 macOS 15+ 上构建，目标为
  `macosx-version-min=14.0`。
- **Windows (amd64)**：Rust 扩展（`lnt_shared`、`jsonic`）因底层 crate 仅限
  POSIX 平台而未包含。数据库驱动和事务封装正常提供。
