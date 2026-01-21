#!/usr/bin/env lua

local function run(cmd)
    local handle = io.popen(cmd .. " 2>&1")
    local result = handle:read("*a")
    handle:close()
    return result
end

local function check_command(cmd)
    local result = run("which " .. cmd)
    return result ~= "" and result or nil
end

local function log(msg, level)
    level = level or "INFO"
    print("[" .. level .. "] " .. msg)
end

local function fail(msg)
    log(msg, "FAIL")
    os.exit(1)
end

local function http_request(method, url, data)
    if not check_command("curl") then
        fail("curl is required")
    end
    
    local cmd = "curl -s -X " .. method .. " '" .. url .. "'"
    if data then
        cmd = cmd .. " -H 'Content-Type: application/json' -d '" .. data:gsub("'", "'\\''") .. "'"
    end
    
    return run(cmd)
end

local function json_encode(tbl)
    local function encode_value(val)
        if type(val) == "string" then
            return '"' .. val:gsub('"', '\\"') .. '"'
        elseif type(val) == "number" then
            return tostring(val)
        elseif type(val) == "boolean" then
            return val and "true" or "false"
        elseif type(val) == "table" then
            local result = "{"
            local first = true
            for k, v in pairs(val) do
                if not first then result = result .. "," end
                result = result .. '"' .. k .. '":' .. encode_value(v)
                first = false
            end
            result = result .. "}"
            return result
        end
        return "null"
    end
    return encode_value(tbl)
end

local function test_registration(base_url)
    log("Testing user registration on " .. base_url)
    
    local user_data = {
        user = {
            username = "testuser" .. os.time(),
            email = "test" .. os.time() .. "@example.com",
            password = "password123"
        }
    }
    
    local response = http_request("POST", base_url .. "/api/users", json_encode(user_data))
    if response:find("error", 1, true) then
        log("Registration response (may be expected error if user exists):", "WARN")
        print(response)
        return false
    else
        log("Registration successful", "OK")
        print(response)
        return true
    end
end

local function test_login(base_url, username, password)
    log("Testing user login on " .. base_url)
    
    local login_data = {
        user = {
            email = username,
            password = password
        }
    }
    
    local response = http_request("POST", base_url .. "/api/users/login", json_encode(login_data))
    if response:find("error", 1, true) or response:find("Error", 1, true) then
        log("Login failed:", "WARN")
        print(response)
        return nil
    else
        log("Login successful", "OK")
        
        -- Try to extract token
        if response:find('"token"') then
            local token = response:match('"token":"([^"]+)"')
            if token then
                log("Token extracted: " .. token:sub(1, 20) .. "...", "OK")
                return token
            end
        end
        print(response)
        return nil
    end
end

local function test_create_article(base_url, token)
    if not token then
        log("Skipping article creation - no token", "WARN")
        return false
    end
    
    log("Testing article creation on " .. base_url)
    
    local article_data = {
        article = {
            title = "Test Article " .. os.time(),
            description = "This is a test article",
            body = "This is the body of the test article",
            tagList = {"test", "benchmark"}
        }
    }
    
    local cmd = "curl -s -X POST '" .. base_url .. "/api/articles' " ..
                "-H 'Content-Type: application/json' " ..
                "-H 'Authorization: Bearer " .. token .. "' " ..
                "-d '" .. json_encode(article_data):gsub("'", "'\\''") .. "'"
    
    local response = run(cmd)
    if response:find("error", 1, true) or response:find("Error", 1, true) then
        log("Article creation response:", "WARN")
        print(response)
        return false
    else
        log("Article creation successful", "OK")
        print(response)
        return true
    end
end

-- Main
local cmd = arg[1]
if not cmd then
    log("Usage: realworld_tools.lua <command> [options]", "WARN")
    print("Commands:")
    print("  register <base_url>          Test user registration")
    print("  login <base_url> <email>    Test user login (will prompt for password)")
    print("  article <base_url> <token>  Test article creation")
    print("")
    print("Examples:")
    print("  realworld_tools.lua register http://localhost:8000")
    print("  realworld_tools.lua login http://localhost:8000 test@example.com")
    os.exit(1)
end

local base_url = arg[2] or "http://localhost:8000"

if cmd == "register" then
    test_registration(base_url)
elseif cmd == "login" then
    local email = arg[3]
    if not email then
        fail("Email required for login command")
    end
    log("Enter password for " .. email .. ":")
    local password = io.read()
    test_login(base_url, email, password)
elseif cmd == "article" then
    local token = arg[3]
    if not token then
        fail("Token required for article command")
    end
    test_create_article(base_url, token)
elseif cmd == "test-all" then
    log("Running full test suite...")
    test_registration(base_url)
    
    local email = "test" .. os.time() .. "@example.com"
    local password = "password123"
    
    local user_data = {
        user = {
            username = "testuser" .. os.time(),
            email = email,
            password = password
        }
    }
    
    log("Registering test user...", "INFO")
    run("curl -s -X POST '" .. base_url .. "/api/users' " ..
        "-H 'Content-Type: application/json' " ..
        "-d '" .. json_encode(user_data):gsub("'", "'\\''") .. "'" .. " > /dev/null")
    
    log("Logging in...", "INFO")
    local token = test_login(base_url, email, password)
    if token then
        test_create_article(base_url, token)
    end
    
    log("Full test suite completed", "OK")
else
    fail("Unknown command: " .. cmd)
end
