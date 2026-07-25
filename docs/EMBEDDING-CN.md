# 从发布 SDK 嵌入 Lunet

每个发布版本都会与 `lunet-run` 一同发布按平台区分的 SDK 压缩包：

- `lunet-linux-amd64-sdk.tar.gz`
- `lunet-macos-sdk.tar.gz`
- `lunet-windows-amd64-sdk.zip`

SDK 允许原生应用链接 Lunet，并把 Lua 应用编译到自己的可执行文件中。它不打包
LuaJIT、libuv 或 zlib；请为目标平台安装匹配的开发库和运行时库。

## SDK 布局

```text
bin/generate_embed_scripts.lua
examples/sdk_embed/main.c
examples/sdk_embed/app/main.lua
include/lunet.h
include/lunet_exports.h
lib/liblunet-static.a                 # Linux/macOS
lib/lunet-static.lib                  # Windows
```

`generate_embed_scripts.lua` 通过 `xmake lua` 执行；xmake 只用于运行提供的
Lua 生成器，不用于重新构建 Lunet。因为 xmake 执行独立文件时不会转发普通脚本
参数，所以请设置它的三个输入环境变量。

## 构建嵌入式可执行文件

解压 SDK，并从应用目录生成 C 头文件：

```sh
mkdir generated
LUNET_EMBED_SOURCE=examples/sdk_embed/app \
LUNET_EMBED_OUTPUT=generated/lunet_embed_scripts_blob.h \
LUNET_EMBED_PROJECT_ROOT="$PWD" \
xmake lua bin/generate_embed_scripts.lua
```

在 Linux 上，安装 LuaJIT、libuv 和 zlib 开发包后：

```sh
cc -std=c99 -Iinclude -Igenerated \
  $(pkg-config --cflags luajit libuv zlib) \
  examples/sdk_embed/main.c lib/liblunet-static.a \
  $(pkg-config --libs luajit libuv zlib) -pthread -ldl -lm \
  -o my-lunet-app
./my-lunet-app
```

在 macOS 上，安装 Homebrew 的 `luajit`、`libuv`、`zlib` 和 `pkg-config` 后：

```sh
export PKG_CONFIG_PATH="$(brew --prefix zlib)/lib/pkgconfig:$PKG_CONFIG_PATH"
cc -std=c99 -Iinclude -Igenerated \
  $(pkg-config --cflags luajit libuv zlib) \
  examples/sdk_embed/main.c lib/liblunet-static.a \
  $(pkg-config --libs luajit libuv zlib) -o my-lunet-app
./my-lunet-app
```

在 Windows 上，用 vcpkg 安装 `luajit:x64-windows`、`libuv:x64-windows` 和
`zlib:x64-windows`，然后在 Visual Studio 开发人员命令提示符中执行：

```powershell
cl /nologo /std:c11 /I include /I generated `
  /I "$env:VCPKG_ROOT\installed\x64-windows\include" `
  examples\sdk_embed\main.c lib\lunet-static.lib /link `
  /LIBPATH:"$env:VCPKG_ROOT\installed\x64-windows\lib" `
  lua51.lib uv.lib zlib.lib ws2_32.lib iphlpapi.lib userenv.lib psapi.lib `
  advapi32.lib user32.lib shell32.lib ole32.lib dbghelp.lib /OUT:my-lunet-app.exe
.\my-lunet-app.exe
```

## C API 和生命周期

`include/lunet.h` 提供不透明的 `lunet_runtime_t` 和四个函数：

1. 调用一次 `lunet_runtime_init`；可选地提供可执行文件路径以及
   `dangerously_skip_loopback_restriction=1`。
2. 只能调用一次 `lunet_runtime_run_file` 或
   `lunet_runtime_run_embedded`。
3. 将返回的 API 状态与输出的应用退出码分开处理。
4. 初始化成功后始终调用 `lunet_runtime_shutdown`。

运行时每个进程仅支持一次初始化和一次应用运行，因为 Lunet 使用一个默认 Lua
状态和 libuv 事件循环。`run_embedded` 只接受安全的相对入口脚本路径，并会在运行
前验证 `LUNETPK1` gzip blob。仅绑定回环地址仍是默认行为；危险的退出选项在
`lunet_runtime_options_t` 中显式指定。

静态核心不包含可选数据库驱动、PAXE、HTTP 客户端或发布压缩包中的扩展模块。
应用使用它们时请单独分发。
