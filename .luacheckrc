-- Luacheck configuration for Lunet (LuaJIT / Lua 5.1)
-- Run via: xmake check
std = "lua51"

-- Globals provided by the busted test framework (used in spec/)
globals = {
    "describe", "it", "pending",
    "setup", "teardown",
    "before_each", "after_each",
    "spy", "stub", "mock",
    "insulate", "expose",
    -- Lunet runtime exit-code convention (used by smoke tests and scripts)
    "__lunet_exit_code",
}

-- Read-only globals available in LuaJIT but not standard Lua 5.1
read_globals = {
    -- package.searchpath is Lua 5.2+ but is provided by LuaJIT
    package = { fields = { "searchpath" } },
}

-- Directories that should not be linted
exclude_files = {
    "deps/**",
    "build/**",
    ".luarocks/**",
    -- bin/ scripts run inside the xmake/LuaJIT environment which exposes
    -- extra globals (path, os.files, io.readfile, etc.) not in stock Lua 5.1
    "bin/**",
}

-- Type declaration stubs: unused arguments are inherent to the pattern
files["types/"] = {
    ignore = { "211", "212" },
}
