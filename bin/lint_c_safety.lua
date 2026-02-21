-- ANSI Colors
local RED = "\27[31m"
local GREEN = "\27[32m"
local NC = "\27[0m"

local violations_count = 0
local files_with_violations = 0

-- Helper to recursively find files
local function find_files(dir, extension, files)
    files = files or {}
    -- Fast path when run under xmake lua: use xmake's own file globbing.
    if type(os) == "table" and type(os.files) == "function" then
        for _, p in ipairs(os.files(dir .. "/**." .. extension)) do
            table.insert(files, p)
        end
        return files
    end

    local ok, lfs = pcall(require, "lfs")
    if ok and lfs then
        local mode = lfs.attributes(dir, "mode")
        if mode ~= "directory" then return files end

        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local path = dir .. "/" .. entry
                local attr = lfs.attributes(path)
                if attr.mode == "directory" then
                    find_files(path, extension, files)
                elseif attr.mode == "file" and path:match("%." .. extension .. "$") then
                    table.insert(files, path)
                end
            end
        end
        return files
    end

    if package.config:sub(1, 1) == "\\" then
        -- Windows fallback without lfs.
        local cmd = string.format('dir /b /s "%s\\*.%s"', dir:gsub("/", "\\"), extension)
        local h = io.popen(cmd)
        if h then
            for line in h:lines() do
                table.insert(files, line:gsub("\\", "/"))
            end
            h:close()
        end
        return files
    end

    -- POSIX fallback without lfs.
    local cmd = string.format('find "%s" -type f -name "*.%s" 2>/dev/null', dir, extension)
    local h = io.popen(cmd)
    if h then
        for line in h:lines() do
            table.insert(files, line)
        end
        h:close()
    end
    return files
end

-- Check a single file for violations
local function check_file(path)
    local filename = path:match("([^/]+)$")
    
    -- Skip implementation files allowed to use internals
    if filename:match("_impl%.c$") or 
       filename == "trace.c" or 
       filename == "co.c" or 
       filename == "trace.h" or 
       filename == "co.h" then
        return true
    end

    local f = io.open(path, "r")
    if not f then return true end
    local content = f:read("*all")
    f:close()

    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    local file_violations = {}

    for i, line in ipairs(lines) do
        -- Skip comments (simple heuristic)
        local code_part = line:match("^(.-)//") or line:match("^(.-)/%*") or line
        
        -- Rule 1: No _lunet_* internal calls
        -- Excluding definitions "int _lunet_..." or "void _lunet_..."
        -- Excluding luaopen_lunet_* (Lua module entry points)
        if code_part:match("_lunet_[%w_]+%s*%(") and 
           not code_part:match("int%s+_lunet_") and 
           not code_part:match("void%s+_lunet_") and
           not code_part:match("luaopen_lunet_") then
            table.insert(file_violations, {
                line = i,
                content = line,
                msg = "Internal call. Use safe wrapper (e.g., lunet_ensure_coroutine)"
            })
        end

        -- Rule 2: No raw luaL_ref(..., LUA_REGISTRYINDEX)
        if code_part:match("luaL_ref%s*%(.*LUA_REGISTRYINDEX") then
            table.insert(file_violations, {
                line = i,
                content = line,
                msg = "Unsafe ref creation. Use lunet_coref_create()"
            })
        end

        -- Rule 3: No raw luaL_unref(..., LUA_REGISTRYINDEX, ...)
        if code_part:match("luaL_unref%s*%(.*LUA_REGISTRYINDEX") then
            table.insert(file_violations, {
                line = i,
                content = line,
                msg = "Unsafe ref release. Use lunet_coref_release()"
            })
        end
    end

    if #file_violations > 0 then
        print(string.format("%sVIOLATION%s in %s:", RED, NC, path))
        for _, v in ipairs(file_violations) do
            print(string.format("  %d: %s", v.line, v.content:gsub("^%s+", "")))
            print(string.format("     -> %s", v.msg))
        end
        print("")
        violations_count = violations_count + #file_violations
        files_with_violations = files_with_violations + 1
        return false
    end

    return true
end

-- Main
print("=== C Safety Lint (Lua) ===")
print("Checking for unsafe internal function calls and reference tracking bypasses...\n")

-- Get project root (assuming script is in bin/)
local script_path = debug.getinfo(1).source:match("@(.*)$")
local bin_dir = script_path:match("(.*/)[^/]+$") or "./"
local root_dir = bin_dir .. "../"

-- Collect files
local c_files = {}
find_files(root_dir .. "src", "c", c_files)
find_files(root_dir .. "ext", "c", c_files)
find_files(root_dir .. "opt", "c", c_files)

local h_files = {}
find_files(root_dir .. "include", "h", h_files)
find_files(root_dir .. "ext", "h", h_files)
find_files(root_dir .. "opt", "h", h_files)

-- Process files
for _, path in ipairs(c_files) do check_file(path) end
for _, path in ipairs(h_files) do check_file(path) end

-- Summary
print("=== Summary ===")
if violations_count == 0 then
    print(string.format("%sAll checks passed!%s No violations found.", GREEN, NC))
    os.exit(0)
else
    print(string.format("%sFound %d violations in %d file(s).%s", RED, violations_count, files_with_violations, NC))
    print("\nPlease fix these issues to ensure zero-cost tracing works correctly.")
    print("See AGENTS.md for the full C Code Conventions.")
    os.exit(1)
end
