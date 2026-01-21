local db = require('lunet.db')

print("Testing db.escape() security...")

local vectors = {
    { name = "Basic Injection", input = "' OR '1'='1" },
    { name = "Comment Attack",  input = "admin' --" },
    { name = "Backslash Path",  input = "C:\\Windows\\System32" },
    { name = "Mixed Quotes",    input = [[It's a "feature" \ bug]] },
    { name = "Empty String",    input = "" },
}

for _, v in ipairs(vectors) do
    local escaped = db.escape(v.input)
    print(string.format("Vector: %-15s | Input: %-25s | Escaped: %s", v.name, v.input, escaped))
end
