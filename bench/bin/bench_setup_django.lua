#!/usr/bin/env lua
--[[
Django RealWorld Benchmark Setup Script

Uses simbo1905/realWorld-DjangoRestFramework (fork with JWT fix) with:
- mise-managed Python 3.12 (required - Python 3.14 has compatibility issues)
- PostgreSQL database (conduit)
- Port 9090 for API, 9091 for nginx frontend
]]

local function run(cmd)
    local handle = io.popen(cmd .. " 2>&1")
    local result = handle:read("*a")
    handle:close()
    return result
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function log(msg)
    print("[BENCH-DJANGO] " .. msg)
end

local function fail(msg)
    print("[BENCH-DJANGO] ERROR: " .. msg)
    os.exit(1)
end

-- Get git root
local git_root = run("git rev-parse --show-toplevel 2>/dev/null"):gsub("%s+$", "")
if git_root == "" then
    git_root = run("pwd"):gsub("%s+$", "")
end

local tmp_dir = git_root .. "/.tmp"
local django_dir = tmp_dir .. "/bench/django"
local venv_dir = django_dir .. "/venv"

-- Ensure directories exist
run("mkdir -p " .. tmp_dir .. "/bench")

log("Git root: " .. git_root)
log("Django dir: " .. django_dir)

-- Check for mise and Python 3.12
log("Checking for mise-managed Python 3.12...")
local mise_check = run("mise list python 2>/dev/null")
if not mise_check:find("3.12") then
    fail("Python 3.12 not installed via mise. Run: mise install python@3.12 && mise use python@3.12")
end

-- Get mise Python path
local python_cmd = 'eval "$(mise activate bash)" && python3'
local python_version = run(python_cmd .. " --version 2>&1")
if not python_version:find("3.12") then
    log("Warning: mise Python may not be active in this shell")
    log("Python version: " .. python_version:gsub("%s+$", ""))
end

-- Clone repository if needed
if file_exists(django_dir .. "/manage.py") then
    log("Django app already exists, skipping clone")
else
    log("Cloning simbo1905/realWorld-DjangoRestFramework (fork with JWT fix)...")
    run("rm -rf " .. django_dir .. " 2>/dev/null")
    local clone_result = run("git clone --depth 1 https://github.com/simbo1905/realWorld-DjangoRestFramework.git " .. django_dir)
    if not file_exists(django_dir .. "/manage.py") then
        fail("Failed to clone repository: " .. clone_result)
    end
    log("Clone complete")
end

-- Create/recreate venv with mise Python
if not file_exists(venv_dir .. "/bin/python") then
    log("Creating virtual environment with mise Python 3.12...")
    local venv_cmd = 'cd ' .. git_root .. ' && eval "$(mise activate bash)" && python3 -m venv ' .. venv_dir
    run(venv_cmd)
    if not file_exists(venv_dir .. "/bin/python") then
        fail("Failed to create virtual environment")
    end
end

-- Check venv Python version
local venv_python = venv_dir .. "/bin/python"
local venv_version = run(venv_python .. " --version 2>&1"):gsub("%s+$", "")
log("Venv Python: " .. venv_version)

if not venv_version:find("3.12") then
    log("Warning: venv not using Python 3.12, recreating...")
    run("rm -rf " .. venv_dir)
    local venv_cmd = 'cd ' .. git_root .. ' && eval "$(mise activate bash)" && python3 -m venv ' .. venv_dir
    run(venv_cmd)
end

-- Install dependencies
log("Installing dependencies...")
local pip_cmd = venv_dir .. "/bin/pip"

-- First install setuptools (needed for pkg_resources on Python 3.12+)
run(pip_cmd .. " install --quiet setuptools")

-- Install from requirements.txt
if file_exists(django_dir .. "/requirements.txt") then
    local install_result = run(pip_cmd .. " install -r " .. django_dir .. "/requirements.txt 2>&1")
    if install_result:find("error", 1, true) and not install_result:find("Successfully") then
        log("Pip install output:")
        print(install_result)
        fail("Failed to install dependencies")
    end
    log("Dependencies installed")
else
    fail("requirements.txt not found")
end

-- Verify Django installation
local django_version = run(venv_python .. " -c 'import django; print(django.get_version())' 2>&1"):gsub("%s+$", "")
if django_version == "" or django_version:find("Error") then
    fail("Django not installed correctly")
end
log("Django version: " .. django_version)

-- Check PostgreSQL connectivity
log("Checking PostgreSQL connection...")
local pg_check = run("psql -h 127.0.0.1 -U $(whoami) -c 'SELECT 1' conduit 2>&1")
if not pg_check:find("1 row") then
    log("PostgreSQL check failed. Ensure:")
    log("  1. PostgreSQL is running: brew services start postgresql")
    log("  2. Database exists: createdb conduit")
    fail("PostgreSQL not accessible")
end
log("PostgreSQL connection OK")

-- Run migrations
log("Running migrations...")
local migrate_cmd = "cd " .. django_dir .. " && " .. venv_python .. " manage.py migrate --noinput 2>&1"
local migrate_result = run(migrate_cmd)
if migrate_result:find("error", 1, true) or migrate_result:find("Error", 1, true) then
    if not migrate_result:find("already exists") and not migrate_result:find("No migrations") then
        log("Migration output:")
        print(migrate_result)
        log("Migrations may have failed - check output above")
    end
end
log("Migrations complete")

-- Summary
log("")
log("=== Setup Complete ===")
log("Django app: " .. django_dir)
log("Python venv: " .. venv_dir)
log("Database: PostgreSQL (conduit @ 127.0.0.1:5432)")
log("")
log("To start manually:")
log("  cd " .. django_dir)
log("  venv/bin/python manage.py runserver 9090")
log("")
log("Or use the start script:")
log("  bench/bin/bench_start_django.sh")
