#!/usr/bin/env -S ./build/lunet
--[[
Database Debug/Exploration Script for Lunet Conduit

Usage (from project root):
  ./build/lunet bin/debug_db.lua

Since lunet doesn't pass command-line args, this script runs interactively
or you can edit the 'cmd' variable below.
]]

package.path = package.path .. ";/Users/Shared/lunet/?.lua"

local lunet = require("lunet")
local mysql = require("lunet.mysql")
local db_config = require("app.db_config")

local function connect()
    local conn, err = mysql.open(db_config)
    if not conn then
        print("ERROR: Database connection failed: " .. (err or "unknown"))
        os.exit(1)
    end
    return conn
end

local function query(conn, sql)
    local rows, err = mysql.query(conn, sql)
    if not rows then
        print("ERROR: Query failed: " .. (err or "unknown"))
        print("SQL: " .. sql)
        return nil
    end
    return rows
end

local function print_table(rows, columns)
    if not rows or #rows == 0 then
        print("(no rows)")
        return
    end
    
    columns = columns or {}
    if #columns == 0 then
        for k, _ in pairs(rows[1]) do
            columns[#columns + 1] = k
        end
        table.sort(columns)
    end
    
    local widths = {}
    for _, col in ipairs(columns) do
        widths[col] = #col
    end
    for _, row in ipairs(rows) do
        for _, col in ipairs(columns) do
            local val = tostring(row[col] or "NULL")
            if #val > widths[col] then
                widths[col] = math.min(#val, 40)
            end
        end
    end
    
    local header = {}
    local sep = {}
    for _, col in ipairs(columns) do
        header[#header + 1] = string.format("%-" .. widths[col] .. "s", col)
        sep[#sep + 1] = string.rep("-", widths[col])
    end
    print(table.concat(header, " | "))
    print(table.concat(sep, "-+-"))
    
    for _, row in ipairs(rows) do
        local vals = {}
        for _, col in ipairs(columns) do
            local val = tostring(row[col] or "NULL")
            if #val > 40 then val = val:sub(1, 37) .. "..." end
            vals[#vals + 1] = string.format("%-" .. widths[col] .. "s", val)
        end
        print(table.concat(vals, " | "))
    end
    print("\n(" .. #rows .. " rows)")
end

local function cmd_tables(conn)
    local rows = query(conn, "SHOW TABLES")
    if rows then
        print("Tables in database '" .. db_config.database .. "':\n")
        for _, row in ipairs(rows) do
            for _, v in pairs(row) do
                print("  - " .. v)
            end
        end
    end
end

local function cmd_schema(conn, table_name)
    if not table_name then
        print("Usage: debug_db.lua schema <table_name>")
        return
    end
    local rows = query(conn, "DESCRIBE " .. table_name)
    if rows then
        print("Schema for '" .. table_name .. "':\n")
        print_table(rows, {"Field", "Type", "Null", "Key", "Default"})
    end
end

local function cmd_users(conn, limit)
    limit = tonumber(limit) or 10
    local rows = query(conn, "SELECT id, username, email, bio, created_at FROM users ORDER BY created_at DESC LIMIT " .. limit)
    if rows then
        print("Users (most recent " .. limit .. "):\n")
        print_table(rows, {"id", "username", "email", "bio", "created_at"})
    end
end

local function cmd_articles(conn, limit)
    limit = tonumber(limit) or 10
    local rows = query(conn, [[
        SELECT a.id, a.slug, a.title, u.username as author, a.created_at 
        FROM articles a 
        JOIN users u ON u.id = a.author_id 
        ORDER BY a.created_at DESC 
        LIMIT ]] .. limit)
    if rows then
        print("Articles (most recent " .. limit .. "):\n")
        print_table(rows, {"id", "slug", "title", "author", "created_at"})
    end
end

local function cmd_tags(conn)
    local rows = query(conn, "SELECT t.id, t.name, COUNT(at.article_id) as article_count FROM tags t LEFT JOIN article_tags at ON at.tag_id = t.id GROUP BY t.id, t.name ORDER BY article_count DESC")
    if rows then
        print("Tags:\n")
        print_table(rows, {"id", "name", "article_count"})
    end
end

local function cmd_query(conn, sql)
    if not sql then
        print("Usage: debug_db.lua query \"<sql>\"")
        return
    end
    local rows = query(conn, sql)
    if rows then
        print_table(rows)
    end
end

local function cmd_help()
    print([[
Database Debug/Exploration Script for Lunet Conduit

Usage: ./bin/debug_db.lua [command] [args...]

Commands:
  tables          - List all tables
  schema <table>  - Show table schema  
  users [limit]   - List users (default: 10)
  articles [limit] - List articles (default: 10)
  tags            - List tags with article counts
  query <sql>     - Run raw SQL query
  help            - Show this help

Connection: ]] .. db_config.host .. ":" .. db_config.port .. "/" .. db_config.database .. " as " .. db_config.user .. [[

Examples:
  ./bin/debug_db.lua tables
  ./bin/debug_db.lua users 5
  ./bin/debug_db.lua articles 10
  ./bin/debug_db.lua schema users
  ./bin/debug_db.lua query "SELECT COUNT(*) as cnt FROM articles"
]])
end

local function main()
    print("=== Lunet Conduit Database Explorer ===\n")
    print("Connecting to " .. db_config.host .. ":" .. db_config.port .. "/" .. db_config.database .. "...")
    local conn = connect()
    print("Connected.\n")
    
    print("--- TABLES ---")
    cmd_tables(conn)
    print("")
    
    print("--- USERS (last 10) ---")
    cmd_users(conn, 10)
    print("")
    
    print("--- ARTICLES (last 10) ---")
    cmd_articles(conn, 10)
    print("")
    
    print("--- TAGS ---")
    cmd_tags(conn)
    
    mysql.close(conn)
    print("\nDone.")
    os.exit(0)
end

lunet.spawn(main)
