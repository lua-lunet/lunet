# lunet.jsonic 演示的 Maelstrom 测试平台

端到端测试平台,使用 [Maelstrom](https://github.com/jepsen-io/maelstrom)(Jepsen
的分布式系统工作台)的 `echo` 工作负载对 `lunet.jsonic` 扩展进行压测。

全部在 Docker 中运行,目标平台为 `linux/arm64`(兼容 colima),使用**经典构建器**
(`DOCKER_BUILDKIT=0`),**不使用卷挂载**,服务端**仅监听回环地址** ——
符合本仓库的安全规则。

## 架构

Maelstrom 的节点是通过 stdin/stdout 驱动的普通进程,每行一条 JSON-RPC 消息。
lunet 的服务端是 HTTP 服务,因此在 rig 容器内用一个极小的 shim 在两种协议之间架桥:

```
        rig 容器(与 demo 共享网络命名空间)
 ┌──────────────────────────────────────────────────────────┐
 │  maelstrom(JDK 21)                                      │
 │     │ 按节点拉起                                         │
 │     ▼                                                    │
 │  shim.sh -> lunet-run shim.lua                           │
 │     stdin/stdout JSON 行  ⇄  lunet.httpc(libcurl)       │
 └──────────────┬───────────────────────────────────────────┘
                │ HTTP POST 127.0.0.1:18090/msg(回环)
 ┌──────────────▼───────────────────────────────────────────┐
 │  demo 容器                                               │
 │  lunet-run server.lua -> socket.listen + lunet.jsonic    │
 │  (init -> init_ok,echo -> echo_ok)                      │
 └──────────────────────────────────────────────────────────┘
```

`network_mode: "service:demo"` 让两个容器处于同一网络命名空间,因此
`127.0.0.1` 可以跨容器互通,无需发布端口,也无需绑定 `0.0.0.0`。

## 文件说明

| 文件 | 用途 |
|---|---|
| `server.lua` | 以 lunet HTTP 服务实现的 Maelstrom 节点(JSON 由 `lunet.jsonic` 处理) |
| `shim.lua` | stdin/stdout ⇄ HTTP 桥,经由 `lunet.httpc`(在 `lunet-run` 下运行) |
| `shim.sh` | Maelstrom 按节点拉起的 `--bin` 包装脚本 |
| `run-test.sh` | rig 入口:等待 `/health` 就绪后执行 `maelstrom test -w echo` |
| `Dockerfile.demo` | 从源码构建 lunet + jsonic + httpc;精简运行时承载节点服务 |
| `Dockerfile.rig` | JDK 21 + graphviz + gnuplot + Maelstrom v0.2.4(sha256 锁定)+ shim |
| `docker-compose.yml` | 编排 demo 与 rig(共享网络命名空间) |
| `Makefile` | `build` / `test` / `results` / `clean` |

## 用法

```sh
make -C ext/jsonic/maelstrom test      # 构建镜像并运行 echo 负载;失败时退出码非零
make -C ext/jsonic/maelstrom build     # 仅构建两个镜像(先 demo:rig 镜像 FROM 它)
make -C ext/jsonic/maelstrom results   # 从运行中的 rig 容器拷出 /app/store
make -C ext/jsonic/maelstrom clean     # compose down 并删除镜像
```

可调参数(环境变量 / make 变量):`WORKLOAD`(默认 `echo`)、
`NODE_COUNT`(默认 `1`)、`TIME_LIMIT`(默认 `10` 秒):

```sh
TIME_LIMIT=30 make -C ext/jsonic/maelstrom test
```

每次 `make test` 都会把 Maelstrom 的 `store/`(历史、分析、图表)
复制到 `.tmp/maelstrom-results-<时间戳>/store/`,无需卷挂载;
运行结束时会打印该路径。

成功输出形如:

```
:valid? true
Everything looks good! ヽ(‘ー`)ノ
```

## 本地(非 Docker)冒烟

```sh
# 1. 先构建一次依赖
xmake build-release && xmake build lunet-httpc && xmake build-jsonic

# 2. 后台启动节点服务
LUNET_JSONIC_LIB=$PWD/ext/jsonic/target/release/liblunet_jsonic.dylib \
  ./build/macosx/arm64/release/lunet-run ext/jsonic/maelstrom/server.lua &

# 3. 通过 shim 发送一条消息
printf '%s\n' '{"src":"c1","dest":"n1","body":{"type":"echo","msg_id":1,"echo":"hi"}}' \
  | ./build/macosx/arm64/release/lunet-run ext/jsonic/maelstrom/shim.lua
# -> {"dest":"c1","src":"n1","body":{"type":"echo_ok","in_reply_to":1,"echo":"hi",...}}
```

## 备注

- **Maelstrom 来源**:镜像构建时从官方 v0.2.4 GitHub release 下载,
  SHA256 已锁定(`301ec71d…85799`)。本仓库不内置任何 Maelstrom 代码。
  发布包内置预编译 uberjar,因此只需 JRE,无需 leiningen/clojure 工具链。
- **rig 镜像中的 `git` 是必需的**:Jepsen 启动时会调用 `git` 记录测试版本。
- **shim 为何要在 `lunet-run` 下运行**:`lunet.httpc` 基于协程 + libuv,
  裸 LuaJIT 无法驱动。
- **仅回环**:服务端绑定 `127.0.0.1`(由 lunet 的 socket 层强制)。
  跨容器可达性来自共享网络命名空间,而非 `0.0.0.0`。
