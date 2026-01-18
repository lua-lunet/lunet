# RealWorld Conduit on Lunet

This is a backend implementation of the [RealWorld Conduit API](https://realworld.io) using the **Lunet** framework (LuaJIT + libuv).

## Architecture

- **Runtime**: Lunet (custom C + LuaJIT + libuv)
- **Database**: MariaDB (running in Lima VM)
- **Crypto**: libsodium (via FFI)
- **JSON**: Pure Lua implementation

## Prerequisites

1. **Lunet**: Built from source in this repo (`build/lunet`).
2. **MariaDB**: Running in a Lima VM instance named `mariadb12`.
3. **Libsodium**: `brew install libsodium`

## Configuration

The database configuration is managed in `app/db_config.lua`.
By default, it connects to `127.0.0.1:3306` (host-forwarded from Lima VM).

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

## Running the Server and Frontend

This project includes a complete workflow to run the backend and a RealWorld frontend (Vite React) locally.

1.  **Start Database (if not running):**
    ```bash
    limactl start mariadb12
    ```

2.  **Build API:**
    ```bash
    make build
    ```

3.  **Run API:**
    ```bash
    make run
    ```
    The API will listen on `0.0.0.0:8080`.

4.  **Run Frontend (WUI):**
    ```bash
    make wui
    ```
    This will clone the [React Vite RealWorld Example](https://github.com/romansndlr/react-vite-realworld-example-app), configure it to talk to your local API, and start it.
    Access the UI at: **http://127.0.0.1:5173**

5.  **Stop All:**
    ```bash
    make stop
    ```
    Stops both the API and the Frontend.

## Testing

### Debug Server
A self-contained debug server is available to verify the full stack (Networking + DB):
```bash
./build/lunet app/debug_server.lua
# In another terminal:
curl -v http://127.0.0.1:8090/
```

### API Tests
Use the Postman/Newman collection from the RealWorld repo or simple curl commands.

```bash
# Create user
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"user":{"username":"testuser","email":"test@example.com","password":"password"}}'
```
