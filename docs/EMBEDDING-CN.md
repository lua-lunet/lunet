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
LICENSE
README.md                             # 英文文档
README-CN.md                          # 本文档
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

请按你的应用命名输出文件。下游项目采用的约定是
`<app>-<os>-<arch>.run`（例如 `webdav-linux-amd64.run`）：单一自包含
可执行文件，用户直接运行，无需解压脚本目录树，也无需安装任何其他组件。

## C API 和生命周期

`include/lunet.h` 提供不透明的 `lunet_runtime_t` 和五个函数：

1. 调用一次 `lunet_runtime_init`；可选地提供可执行文件路径以及
   `dangerously_skip_loopback_restriction=1`。
2. 只能调用一次 `lunet_runtime_run_file` 或
   `lunet_runtime_run_embedded`。
3. 将返回的 API 状态与输出的应用退出码分开处理。
4. 调用 `lunet_runtime_request_stop` 请求主动停止（让运行时经历下面的排水点）。
   这是唯一线程安全的调用：宿主可在其他线程调用它，同时 `run_file` /
   `run_embedded` 在运行时线程上阻塞。
5. 初始化成功后始终调用 `lunet_runtime_shutdown`。

运行时每个进程仅支持一次初始化和一次应用运行，因为 Lunet 使用一个默认 Lua
状态和 libuv 事件循环。`run_embedded` 只接受安全的相对入口脚本路径，并会在运行
前验证 `LUNETPK1` gzip blob。仅绑定回环地址仍是默认行为；危险的退出选项在
`lunet_runtime_options_t` 中显式指定。

## 主动停止、排水点与后排水钩子

运行中的应用可自行请求终止（`lunet.stop()`），宿主也可以从 C 调用
`lunet_runtime_request_stop`。语义如下：

- 事件循环立即停止接收新工作（`uv_stop` 结束当前迭代，之后不会有新的
  accept/read 推进）；
- 已经接收的工作继续完成：teardown 会完成挂在仍处于悬停状态的睡眠定时器
  之后的协程；
- 出站写入要么完成，要么被安全放弃；
- 在到达排水点时，注册的后排水 Lua 回调恰好运行一次，且只能进行同步工作：
  此时内存中的状态即最终状态，宿主可以有保障地持久化（写入 WAL，写入
  超级块的 `flushed` 标记）；
- 回调返回后，所有剩余句柄全部关闭，回调被逐层清空，然后调用
  `uv_loop_close` 并检验其返回值。

## 后排水钩子的创建方式

可通过 `lunet.on_stop(fn)` 注册（会替换先前注册的那个）：

```lua
lunet.on_stop(function()
    -- 只做同步操作：事件循环已不再驱动任何内容
    wal.write(state)
    superblock.write_flag("flushed")
end)
lunet.stop()
```

因此宿主构建的生命周期为：事件循环启动前状态为 `running`；请求终止时为
`stopping`；在后排水钩子内部为 `flushed`。下次启动时，`flushed` 表示上一次
进程干净终止；任何其他结尾都说明该进程在关机过程中死亡，必须重放 WAL。

静态核心不包含可选数据库驱动、PAXE、HTTP 客户端或发布压缩包中的扩展模块。
应用使用它们时请单独分发。
