local MAGIC = "LUNETPK1"

local function is_windows()
    return package.config:sub(1, 1) == "\\"
end

local function normalize_path(p)
    return (p or ""):gsub("\\", "/")
end

local function is_abs_path(p)
    if not p or p == "" then
        return false
    end
    if p:sub(1, 1) == "/" or p:sub(1, 1) == "\\" then
        return true
    end
    return p:match("^%a:[/\\]") ~= nil
end

local function join_path(a, b)
    if not a or a == "" then
        return b
    end
    if not b or b == "" then
        return a
    end
    local last = a:sub(-1)
    if last == "/" or last == "\\" then
        return a .. b
    end
    return a .. "/" .. b
end

local function parent_dir(path)
    local m = path:match("^(.*)[/\\][^/\\]+$")
    return m or "."
end

local function ensure_dir(path)
    if type(os) == "table" and type(os.mkdir) == "function" then
        os.mkdir(path)
        return true
    end

    local cmd
    if is_windows() then
        cmd = string.format('mkdir "%s" >nul 2>nul', path:gsub('"', '\\"'))
    else
        cmd = string.format('mkdir -p "%s"', path:gsub('"', '\\"'))
    end
    local a, b, c = os.execute(cmd)
    if type(a) == "number" then
        return a == 0
    end
    if type(a) == "boolean" then
        return a and (c == nil or c == 0)
    end
    return false
end

local function is_dir(path)
    if type(os) == "table" and type(os.isdir) == "function" then
        return os.isdir(path)
    end
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs then
        return lfs.attributes(path, "mode") == "directory"
    end
    return false
end

local function collect_files(root)
    local files = {}
    if type(os) == "table" and type(os.files) == "function" then
        local pattern = normalize_path(root)
        if pattern:sub(-1) ~= "/" then
            pattern = pattern .. "/"
        end
        pattern = pattern .. "**"
        for _, p in ipairs(os.files(pattern)) do
            table.insert(files, p)
        end
        return files
    end

    local ok, lfs = pcall(require, "lfs")
    if ok and lfs then
        local function walk(dir)
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    local p = join_path(dir, entry)
                    local mode = lfs.attributes(p, "mode")
                    if mode == "directory" then
                        walk(p)
                    elseif mode == "file" then
                        table.insert(files, p)
                    end
                end
            end
        end
        walk(root)
        return files
    end

    local cmd
    if is_windows() then
        cmd = string.format('dir /b /s "%s"', root:gsub("/", "\\"))
    else
        cmd = string.format('find "%s" -type f', root)
    end
    local h = io.popen(cmd)
    if h then
        for line in h:lines() do
            table.insert(files, line)
        end
        h:close()
    end
    return files
end

local function rel_path(root, absolute)
    local root_norm = normalize_path(root)
    local abs_norm = normalize_path(absolute)
    if root_norm:sub(-1) ~= "/" then
        root_norm = root_norm .. "/"
    end
    if abs_norm:sub(1, #root_norm) == root_norm then
        return abs_norm:sub(#root_norm + 1)
    end
    return abs_norm
end

local function le_u32(n)
    local x = math.floor(n)
    local b1 = x % 256
    x = (x - b1) / 256
    local b2 = x % 256
    x = (x - b2) / 256
    local b3 = x % 256
    x = (x - b3) / 256
    local b4 = x % 256
    return string.char(b1, b2, b3, b4)
end

local function le_u64(n)
    local x = math.floor(n)
    local out = {}
    for i = 1, 8 do
        local b = x % 256
        out[i] = string.char(b)
        x = (x - b) / 256
    end
    return table.concat(out)
end

local function shell_quote(path)
    if is_windows() then
        return '"' .. path:gsub('"', '\\"') .. '"'
    end
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function run_cmd(cmd)
    local a, b, c = os.execute(cmd)
    if type(a) == "number" then
        return a == 0
    end
    if type(a) == "boolean" then
        return a and (c == nil or c == 0)
    end
    return false
end

local function usage()
    io.stderr:write("usage: xmake lua bin/generate_embed_scripts.lua --source <dir> --output <header> [--project-root <dir>]\n")
    os.exit(1)
end

local function parse_args(argv)
    local args = {source = "lua", project_root = "."}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--source" then
            i = i + 1
            args.source = argv[i]
        elseif a == "--output" then
            i = i + 1
            args.output = argv[i]
        elseif a == "--project-root" then
            i = i + 1
            args.project_root = argv[i]
        else
            io.stderr:write("unknown argument: " .. tostring(a) .. "\n")
            usage()
        end
        i = i + 1
    end
    if not args.output or args.output == "" then
        usage()
    end
    return args
end

local function main()
    local args = parse_args(arg or {})
    local source = args.source
    local output = args.output
    local project_root = args.project_root or "."

    if not is_abs_path(source) then
        source = join_path(project_root, source)
    end
    if not is_abs_path(output) then
        output = join_path(project_root, output)
    end

    if not is_dir(source) then
        io.stderr:write("embed source directory not found: " .. source .. "\n")
        os.exit(1)
    end
    if not ensure_dir(parent_dir(output)) then
        io.stderr:write("failed to create output directory for: " .. output .. "\n")
        os.exit(1)
    end

    local files = collect_files(source)
    local entries = {}
    for _, abs in ipairs(files) do
        local rel = rel_path(source, abs)
        if rel ~= "" then
            table.insert(entries, {abs = abs, rel = rel})
        end
    end
    table.sort(entries, function(a, b)
        return a.rel < b.rel
    end)

    local payload_path = output .. ".payload.bin"
    local gzip_path = output .. ".payload.bin.gz"

    local pf = assert(io.open(payload_path, "wb"))
    pf:write(MAGIC)
    pf:write(le_u32(#entries))
    for _, e in ipairs(entries) do
        local f = assert(io.open(e.abs, "rb"))
        local data = f:read("*a") or ""
        f:close()

        pf:write(le_u32(#e.rel))
        pf:write(le_u64(#data))
        pf:write(e.rel)
        pf:write(data)
    end
    pf:close()

    local gzip_cmd = string.format("gzip -n -c %s > %s", shell_quote(payload_path), shell_quote(gzip_path))
    if not run_cmd(gzip_cmd) then
        io.stderr:write("failed to run gzip command: " .. gzip_cmd .. "\n")
        os.exit(1)
    end

    local gf = assert(io.open(gzip_path, "rb"))
    local gzip_blob = gf:read("*a") or ""
    gf:close()
    if #gzip_blob == 0 then
        io.stderr:write("gzip output is empty\n")
        os.exit(1)
    end

    local out = assert(io.open(output, "wb"))
    out:write("/* Auto-generated by bin/generate_embed_scripts.lua. */\n")
    out:write("#ifndef LUNET_EMBED_SCRIPTS_BLOB_GENERATED_H\n")
    out:write("#define LUNET_EMBED_SCRIPTS_BLOB_GENERATED_H\n\n")
    out:write("#include <stddef.h>\n\n")
    out:write("const unsigned char lunet_embedded_scripts_gzip[] = {\n")
    for i = 1, #gzip_blob do
        if (i - 1) % 12 == 0 then
            out:write("  ")
        end
        out:write(string.format("0x%02x", gzip_blob:byte(i)))
        if i < #gzip_blob then
            out:write(", ")
        end
        if i % 12 == 0 then
            out:write("\n")
        end
    end
    if #gzip_blob % 12 ~= 0 then
        out:write("\n")
    end
    out:write("};\n")
    out:write(string.format("const size_t lunet_embedded_scripts_gzip_len = %d;\n\n", #gzip_blob))
    out:write("#endif\n")
    out:close()

    os.remove(payload_path)
    os.remove(gzip_path)
end

main()
