-- The RealWorld demo chooses its DB at CMake build time, exposed to Lua as:
--   _G.LUNET_DEMO_DB = "sqlite" | "mysql"
-- Default is sqlite (see `CMakeLists.txt`).

local driver = rawget(_G, "LUNET_DEMO_DB") or "sqlite"

if driver == "mysql" then
    return {
        driver = "mysql",
        host = "127.0.0.1",
        port = 3306,
        user = "root",
        password = "root",
        database = "conduit",
        charset = "utf8mb4",
    }
end

return {
    driver = "sqlite",
    path = ".tmp/conduit.sqlite3",
}
