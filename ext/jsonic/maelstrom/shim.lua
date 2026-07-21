--[[
  Maelstrom stdin/stdout -> HTTP shim.

  Maelstrom drives a "node binary" over stdin/stdout, one JSON message per
  line. This shim bridges that protocol to the lunet HTTP server
  (ext/jsonic/maelstrom/server.lua) via lunet.httpc (libcurl):

    stdin line -> POST http://127.0.0.1:18090/msg -> response body -> stdout

  stdout carries ONLY Maelstrom replies; diagnostics go to stderr.

  Run locally (server must already be listening):
    printf '%s\n' '{"src":"c1","dest":"n1","body":{"type":"echo","msg_id":1,"echo":"hi"}}' \
      | ./build/macosx/arm64/release/lunet-run ext/jsonic/maelstrom/shim.lua
]]

local lunet = require("lunet")
local httpc = require("lunet.httpc")

local TARGET = os.getenv("MAELSTROM_TARGET") or "http://127.0.0.1:18090/msg"

lunet.spawn(function()
  local stdin = io.stdin
  while true do
    local line = stdin:read("*l")
    if not line then
      break
    end
    if line ~= "" then
      local res, err = httpc.request({
        url = TARGET,
        method = "POST",
        body = line,
        headers = { ["Content-Type"] = "application/json" },
        timeout_ms = 10000,
      })
      if not res then
        io.stderr:write("shim: httpc error: " .. tostring(err) .. "\n")
        os.exit(1)
      end
      io.write(res.body)
      io.write("\n")
      io.stdout:flush()
    end
  end
end)
