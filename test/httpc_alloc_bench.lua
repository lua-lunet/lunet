-- HTTPC allocator benchmark for comparing baseline/easy_memory profiles.
-- Runs fully offline via file:// URLs so it works in restricted environments.

local lunet = require("lunet")
local ok_httpc, httpc = pcall(require, "lunet.httpc")
if not ok_httpc then
    io.stderr:write("[HTTPC_BENCH][FAIL] could not require lunet.httpc: " .. tostring(httpc) .. "\n")
    _G.__lunet_exit_code = 1
    return
end

local REQUESTS = tonumber(os.getenv("HTTPC_BENCH_REQUESTS")) or 400
local BODY_KB = tonumber(os.getenv("HTTPC_BENCH_BODY_KB")) or 256
local TIMEOUT_MS = tonumber(os.getenv("HTTPC_BENCH_TIMEOUT_MS")) or 5000
local FIXTURE_PATH = os.getenv("HTTPC_BENCH_FIXTURE") or ".tmp/httpc_bench_fixture.txt"
local BODY_BYTES = BODY_KB * 1024

local wall_now_seconds
do
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi then
        local ok_cdef = pcall(function()
            ffi.cdef[[
                struct timeval {
                    long tv_sec;
                    int tv_usec;
                };
                int gettimeofday(struct timeval *tv, void *tz);
            ]]
        end)
        if ok_cdef then
            wall_now_seconds = function()
                local tv = ffi.new("struct timeval")
                if ffi.C.gettimeofday(tv, nil) == 0 then
                    return tonumber(tv.tv_sec) + (tonumber(tv.tv_usec) / 1000000.0)
                end
                return os.clock()
            end
        end
    end
    if not wall_now_seconds then
        wall_now_seconds = function()
            return os.clock()
        end
    end
end

local function ensure_fixture(path, bytes)
    local f, err = io.open(path, "wb")
    if not f then
        return nil, err
    end

    local chunk = string.rep("x", 1024)
    local full_kb = math.floor(bytes / 1024)
    local rem = bytes % 1024
    for _ = 1, full_kb do
        f:write(chunk)
    end
    if rem > 0 then
        f:write(string.rep("y", rem))
    end
    f:close()
    return true
end

local function to_file_url(path)
    local p = path
    if string.sub(p, 1, 1) ~= "/" then
        local pwd = os.getenv("PWD")
        if not pwd or #pwd == 0 then
            return nil, "PWD is not set"
        end
        p = pwd .. "/" .. p
    end
    p = string.gsub(p, " ", "%%20")
    return "file://" .. p
end

lunet.spawn(function()
    local ok_fixture, fixture_err = ensure_fixture(FIXTURE_PATH, BODY_BYTES)
    if not ok_fixture then
        io.stderr:write("[HTTPC_BENCH][FAIL] fixture create failed: " .. tostring(fixture_err) .. "\n")
        _G.__lunet_exit_code = 1
        return
    end

    local url, url_err = to_file_url(FIXTURE_PATH)
    if not url then
        io.stderr:write("[HTTPC_BENCH][FAIL] fixture url failed: " .. tostring(url_err) .. "\n")
        _G.__lunet_exit_code = 1
        return
    end

    local ok_count = 0
    local fail_count = 0
    local cpu_started = os.clock()
    local wall_started = wall_now_seconds()

    for i = 1, REQUESTS do
        local resp, err = httpc.request({
            url = url,
            method = "GET",
            timeout_ms = TIMEOUT_MS,
            max_body_bytes = BODY_BYTES + 1024,
            allow_file_protocol = true,
            headers = {
                {"X-Bench-Run", tostring(i)},
                {"Accept", "text/plain"},
                {"Connection", "close"},
            }
        })

        if not resp then
            fail_count = fail_count + 1
            io.stderr:write("[HTTPC_BENCH][FAIL] request " .. i .. ": " .. tostring(err) .. "\n")
        elseif #resp.body ~= BODY_BYTES then
            fail_count = fail_count + 1
            io.stderr:write("[HTTPC_BENCH][FAIL] request " .. i .. ": body bytes "
                .. tostring(#resp.body) .. " != " .. tostring(BODY_BYTES) .. "\n")
        else
            ok_count = ok_count + 1
        end
    end

    local cpu_elapsed = os.clock() - cpu_started
    if cpu_elapsed <= 0 then
        cpu_elapsed = 0.000001
    end
    local wall_elapsed = wall_now_seconds() - wall_started
    if wall_elapsed <= 0 then
        wall_elapsed = 0.000001
    end

    io.stderr:write(string.format(
        "[HTTPC_BENCH] requests=%d ok=%d fail=%d body_bytes=%d elapsed_wall_s=%.6f req_per_wall_s=%.2f elapsed_cpu_s=%.6f req_per_cpu_s=%.2f\n",
        REQUESTS, ok_count, fail_count, BODY_BYTES,
        wall_elapsed, REQUESTS / wall_elapsed,
        cpu_elapsed, REQUESTS / cpu_elapsed))

    _G.__lunet_exit_code = fail_count > 0 and 1 or 0
end)
