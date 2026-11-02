-- verify_hardening.lua - prove the release hardening flags on the built
-- binaries, per platform. Run through xmake so the MSVC environment is
-- available: `xmake verify-hardening`.
--
-- What is asserted (must all hold, or the task fails):
--   Linux:   lunet-run is PIE (readelf -h: ET_DYN) and references
--            __stack_chk_fail; every ext shared module references
--            __stack_chk_fail; fortified __*_chk symbols are present.
--   macOS:   lunet-run is PIE (otool -hv: PIE flag) and references
--            ___stack_chk_fail; every ext shared module likewise.
--   Windows: lunet-run has DYNAMICBASE set and a /GS security cookie
--            (dumpbin /headers, /loadconfig); every ext DLL likewise.
--
-- Exit status 0 = all assertions held; 1 = at least one failed.

import("core.base.option")
import("detect.sdks.find_vstudio")

local function fail(msg)
    cprint("${red}verify-hardening: FAIL${clear} " .. msg)
    os.exit(1)
end

local function pass(msg)
    cprint("${green}verify-hardening: ok${clear} " .. msg)
end

local function run_tool(cmdline)
    -- os.iorun raises when the tool exits nonzero; callers below treat a
    -- failed lookup as "symbol not found", so catch and return nil. The
    -- xmake Lua sandbox has no pcall: use xmake's try/catch.
    local caught = nil
    local out = try {
        function ()
            return os.iorun(cmdline)
        end,
        catch = function (e)
            caught = e
            return nil
        end
    }
    return out, caught
end

local plat = os.subhost() -- windows / macosx / linux
local builddir = path.join(os.projectdir(), "build", plat, os.subarch(), "release")
if not os.isdir(builddir) then
    fail("release build directory not found: " .. builddir ..
        " (run `xmake f -m release -y && xmake build` first)")
end

local results = {}

-- ------------------------------------------------------------------
-- The main binary
-- ------------------------------------------------------------------

local binname = plat == "windows" and "lunet-run.exe" or "lunet-run"
local binpath = path.join(builddir, binname)
if not os.isfile(binpath) then
    fail("binary not found: " .. binpath)
end

if plat == "linux" then
    local out = run_tool("readelf -h '" .. binpath .. "'")
    if not out or not out:find("DYN") then
        fail("lunet-run is not PIE (readelf -h shows no ET_DYN): " .. binpath)
    end
    pass("PIE (readelf -h: ET_DYN)")

    out = run_tool("nm -D '" .. binpath .. "'")
    if not out or not out:find("stack_chk_fail") then
        fail("lunet-run has no stack-protector reference (nm: __stack_chk_fail)")
    end
    pass("stack protector (nm: __stack_chk_fail)")

    out = run_tool("nm -D '" .. binpath .. "'")
    local out2 = run_tool("nm '" .. binpath .. "'")
    if out2 then
        out = (out or "") .. (out2 or "")
    end
    local fortified = out and (out:find("__printf_chk") or out:find("__memcpy_chk")
        or out:find("__sprintf_chk") or out:find("__snprintf_chk")
        or out:find("__strcpy_chk")) or nil
    if not fortified then
        fail("no fortified __*_chk symbols found (_FORTIFY_SOURCE=2 did not materialise)")
    end
    pass("fortify (nm: __*_chk)")

elseif plat == "macosx" then
    local out = run_tool("otool -hv '" .. binpath .. "'")
    if not out or not out:find("PIE") then
        fail("lunet-run is not PIE (otool -hv shows no PIE flag): " .. binpath)
    end
    pass("PIE (otool -hv)")

    out = run_tool("nm -u '" .. binpath .. "'")
    if not out or not out:find("stack_chk_fail") then
        fail("lunet-run has no stack-protector reference (nm -u: ___stack_chk_fail)")
    end
    pass("stack protector (nm -u: ___stack_chk_fail)")

elseif plat == "windows" then
    -- Find dumpbin through vswhere (the CI runners have it; local VS too).
    local vswhere = "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    if not os.isfile(vswhere) then
        fail("vswhere not found: " .. vswhere)
    end
    local vsroot = run_tool(
        '"' .. vswhere .. '" -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath')
    vsroot = vsroot and vsroot:trim() or nil
    if not vsroot or vsroot == "" then
        fail("Visual Studio C++ tools not located via vswhere")
    end
    local dumpbin = nil
    local msvcdirs = os.dirs(path.join(vsroot, "VC", "Tools", "MSVC", "*"))
    table.sort(msvcdirs)
    for _, d in ipairs(msvcdirs) do
        local candidate = path.join(d, "bin", "Hostx64", "x64", "dumpbin.exe")
        if os.isfile(candidate) then
            dumpbin = candidate
        end
    end
    if not dumpbin then
        fail("dumpbin.exe not found under " .. vsroot)
    end

    local function check_image(imgpath, label)
        local out = run_tool('"' .. dumpbin .. '" /headers "' .. imgpath .. '"')
        if not out or not out:find("Dynamic base") then
            fail(label .. " has no DYNAMICBASE (dumpbin /headers)")
        end
        out = run_tool('"' .. dumpbin .. '" /loadconfig "' .. imgpath .. '"')
        if not out or not out:find("Security Cookie") then
            fail(label .. " has no /GS security cookie (dumpbin /loadconfig)")
        end
        pass(label .. ": DYNAMICBASE + /GS security cookie")
    end

    check_image(binpath, "lunet-run")

    -- Every ext shared module
    local extdir = path.join(builddir, "lunet")
    for _, dll in ipairs(os.files(path.join(extdir, "*.dll"))) do
        check_image(dll, path.filename(dll))
    end

    return -- the ext-module loop below is POSIX-only
end

-- ------------------------------------------------------------------
-- Every ext shared module (.so) references the stack protector
-- ------------------------------------------------------------------

local extdir = path.join(builddir, "lunet")
-- The core runtime module (lunet.so) sits beside the binary; the ext
-- modules live in the lunet/ module directory.
local sofiles = os.files(path.join(builddir, "*.so"))
for _, f in ipairs(os.files(path.join(extdir, "*.so"))) do
    table.insert(sofiles, f)
end
if #sofiles == 0 then
    fail("no shared modules found under " .. builddir)
end
for _, so in ipairs(sofiles) do
    local out = run_tool("nm -D '" .. so .. "'")
    if not out or not out:find("stack_chk_fail") then
        out = run_tool("nm -u '" .. so .. "'")
    end
    if not out or not out:find("stack_chk_fail") then
        fail(path.filename(so) .. " has no stack-protector reference")
    end
    pass(path.filename(so) .. ": stack protector")
end

cprint("${green}verify-hardening: all assertions held on %s/%s${clear}", plat, os.subarch())
