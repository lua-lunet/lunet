local examples = {
  "examples/01_http_json.lua",
  "examples/02_http_routing.lua",
  "examples/03_db_sqlite3.lua",
  "examples/04_db_mysql.lua",
  "examples/05_db_postgres.lua",
  "examples/mcp_openalex_sse/main.lua",
  "examples/mcp_openalex_sse/mcp.lua",
  "examples/mcp_openalex_sse/sse.lua",
  "examples/mcp_openalex_sse/openalex.lua",
  "examples/mcp_openalex_sse/json.lua",
  "examples/mcp_openalex_sse/dotenv.lua",
}

local ok_count = 0
for _, path in ipairs(examples) do
  local chunk, err = loadfile(path)
  if not chunk then
    io.stderr:write(string.format("[examples-test] compile failed: %s: %s\n", path, tostring(err)))
    os.exit(1)
  end
  ok_count = ok_count + 1
end

print(string.format("[examples-test] compiled %d/%d example files", ok_count, #examples))
