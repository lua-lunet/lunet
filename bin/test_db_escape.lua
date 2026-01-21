local db = require("lunet.db")
local s = "test"
local esc = db.escape(s)
print("Escaping: test")
for i=1, #esc do
    io.write(string.format("%02X ", string.byte(esc, i)))
end
print("")
