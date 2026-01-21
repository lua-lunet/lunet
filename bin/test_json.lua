local json = require("app.lib.json")
local s = json.decode('"test"')
print("Decoding: \"test\"")
for i=1, #s do
    io.write(string.format("%02X ", string.byte(s, i)))
end
print("")
