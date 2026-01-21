#!/usr/bin/env lua
local function exec(cmd)
    local handle = io.popen(cmd)
    local result = handle:read("*a")
    handle:close()
    return result
end

local function get_pids(pattern)
    local cmd = "ps aux | grep '" .. pattern .. "' | grep -v grep | awk '{print $2}'"
    local output = exec(cmd)
    local pids = {}
    for pid in output:gmatch("%d+") do
        table.insert(pids, tonumber(pid))
    end
    return pids
end

local function get_rss_sum(pids)
    if #pids == 0 then return 0 end
    local sum = 0
    for _, pid in ipairs(pids) do
        local cmd = "ps -o rss= -p " .. pid
        local rss = exec(cmd):gsub("%s+", "")
        sum = sum + (tonumber(rss) or 0)
    end
    return sum
end

local function run_ab(name, url, count, concurrency)
    print(string.format("--> Benchmarking %s (%s)...", name, url))
    local cmd = string.format("ab -c %d -n %d %s 2>&1", concurrency, count, url)
    local output = exec(cmd)
    
    local rps = output:match("Requests per second:%s+([%d%.]+)")
    local mean = output:match("Time per request:%s+([%d%.]+)%s+%[ms%]%s+%(mean%)")
    
    print(string.format("    RPS: %s, Mean Latency: %s ms", rps or "N/A", mean or "N/A"))
    return tonumber(rps), tonumber(mean)
end

local lunet_pids = get_pids("build/lunet")
local django_pids = get_pids("manage.py runserver")

if #lunet_pids == 0 then print("Error: Lunet not running") end
if #django_pids == 0 then print("Error: Django not running") end

if #lunet_pids == 0 or #django_pids == 0 then os.exit(1) end

print(string.format("Lunet PIDs: %s", table.concat(lunet_pids, ", ")))
print(string.format("Django PIDs: %s", table.concat(django_pids, ", ")))
print("")

local lunet_rss_start = get_rss_sum(lunet_pids)
local django_rss_start = get_rss_sum(django_pids)

print("=== Initial Memory (RSS KB) ===")
print(string.format("Lunet:  %d KB", lunet_rss_start))
print(string.format("Django: %d KB", django_rss_start))
print(string.format("Ratio (D/L): %.2fx", django_rss_start / lunet_rss_start))
print("")

-- Run Load Tests
local requests = 1000
local concurrency = 5

run_ab("Lunet", "http://127.0.0.1:8080/api/tags", requests, concurrency)
run_ab("Django", "http://127.0.0.1:9090/api/tags", requests, concurrency)

print("")
local lunet_rss_end = get_rss_sum(lunet_pids)
local django_rss_end = get_rss_sum(django_pids)

print("=== Final Memory (RSS KB) ===")
print(string.format("Lunet:  %d KB (Delta: %+d KB)", lunet_rss_end, lunet_rss_end - lunet_rss_start))
print(string.format("Django: %d KB (Delta: %+d KB)", django_rss_end, django_rss_end - django_rss_start))
print(string.format("Ratio (D/L): %.2fx", django_rss_end / lunet_rss_end))
