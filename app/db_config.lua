local function is_windows()
    -- LuaJIT provides jit.os; also fall back to path separator check.
    if type(jit) == "table" and jit.os == "Windows" then
        return true
    end
    return package.config:sub(1, 1) == "\\"
end

if is_windows() then
    return {
        driver = "sqlite",
        path = ".tmp/conduit.sqlite3",
    }
end

return {
    driver = "mysql",
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "root",
    database = "conduit",
    charset = "utf8mb4",
}
