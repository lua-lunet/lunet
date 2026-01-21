# 基于 Lunet 的 RealWorld Conduit

这是一个使用 **Lunet**（LuaJIT + libuv）实现的 [RealWorld Conduit API](https://realworld.io) 后端。

[English Documentation](README_realworld.md)

## 架构

- **运行时**：Lunet（自研 C 核心 + LuaJIT + libuv）
- **数据库**：MariaDB（运行于 Lima VM）
- **加密**：libsodium（通过 FFI）
- **JSON**：纯 Lua 实现

## 前置条件

1. **Lunet**：在本仓库中从源码构建（`build/lunet`）。
2. **MariaDB**：运行在名为 `mariadb12` 的 Lima VM 实例中。
3. **Libsodium**：`brew install libsodium`

## 配置

数据库配置位于 `app/db_config.lua`。
默认连接 `127.0.0.1:3306`（由 Lima VM 端口转发到宿主机）。

```lua
return {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "root",
    database = "conduit",
    charset = "utf8mb4"
}
```

## 运行服务端与前端

本项目包含一套完整的本地工作流：运行后端 API + RealWorld 前端（Vite React）。

1.  **启动数据库（如尚未运行）：**
    ```bash
    limactl start mariadb12
    ```

2.  **构建 API：**
    ```bash
    make build
    ```

3.  **运行 API：**
    ```bash
    make run
    ```
    API 将监听在 `0.0.0.0:8080`。

4.  **运行前端（WUI）：**
    ```bash
    make wui
    ```
    该命令会克隆 [React Vite RealWorld Example](https://github.com/romansndlr/react-vite-realworld-example-app)，将其配置为连接本地 API，并启动前端。
    访问地址：**http://127.0.0.1:5173**

5.  **停止全部服务：**
    ```bash
    make stop
    ```
    同时停止 API 与前端。

## 测试

### 调试服务器

提供了一个自包含的调试服务器，用于验证完整链路（网络 + DB）：

```bash
./build/lunet app/debug_server.lua
# 在另一个终端：
curl -v --max-time 3 http://127.0.0.1:8090/
```

### API 测试

你可以使用 RealWorld 仓库提供的 Postman/Newman 集合，或用简单命令进行验证。

```bash
# 创建用户
bin/test_curl.sh -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"user":{"username":"testuser","email":"test@example.com","password":"password"}}'
```
