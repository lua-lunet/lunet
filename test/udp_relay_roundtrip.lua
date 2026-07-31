--[[
  UDP Relay Roundtrip Test

  Proves that a single coroutine can:
    1. recv from a client-facing UDP socket
    2. send to a peer
    3. recv from the peer
    4. send the reply back to the original client

  This is the fundamental pattern needed for the advisory-lock CAS demo.

  Architecture (all in one process, loopback):
    Peer (coroutine 1): echo server on fixed port
    Relay (coroutine 2): client-facing socket + ephemeral peer socket
    Client (coroutine 3): ephemeral socket, sends "hello", expects "hello" back

  Usage:
    ./build/lunet test/udp_relay_roundtrip.lua

  Expected exit code: 0 (all assertions pass)
  Expected exit code: 1 (any assertion fails, or timeout)
]]

local lunet = require("lunet")
local udp = require("lunet.udp")

local PEER_HOST = "127.0.0.1"
local PEER_PORT = 21001
local RELAY_CLIENT_PORT = 21002

local failures = 0
local checks = 0

local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
  else
    print("   OK: " .. msg)
  end
end

-- ── Coroutine 1: Peer (echo server) ──────────────────────────────────────
lunet.spawn(function()
  local h, err = udp.bind(PEER_HOST, PEER_PORT)
  assert(h, err)
  print("PEER: bound on " .. PEER_HOST .. ":" .. PEER_PORT)

  for _ = 1, 3 do
    local data, host, port = udp.recv(h)
    print("PEER: recv '" .. data .. "' from " .. host .. ":" .. port)
    local ok, serr = udp.send(h, host, port, data)
    if not ok then
      io.stderr:write("PEER: send failed: " .. tostring(serr) .. "\n")
    else
      print("PEER: echoed back")
    end
  end

  udp.close(h)
  print("PEER: done")
end)

-- ── Coroutine 2: Relay Node (client-facing + peer-facing) ─────────────────
lunet.spawn(function()
  lunet.sleep(0.1) -- let peer bind first

  local client_sock, cerr = udp.bind(PEER_HOST, RELAY_CLIENT_PORT)
  assert(client_sock, cerr)
  print("RELAY: client socket on " .. PEER_HOST .. ":" .. RELAY_CLIENT_PORT)

  local peer_sock, perr = udp.bind(PEER_HOST, 0)
  assert(peer_sock, perr)
  print("RELAY: peer socket bound (ephemeral)")

  for _ = 1, 3 do
    local data, host, port = udp.recv(client_sock)
    print("RELAY: recv '" .. data .. "' from " .. host .. ":" .. port)

    local ok, serr = udp.send(peer_sock, PEER_HOST, PEER_PORT, data)
    if not ok then
      io.stderr:write("RELAY: send to peer failed: " .. tostring(serr) .. "\n")
    else
      print("RELAY: forwarded to peer")
    end

    local reply = udp.recv(peer_sock)
    check(reply == data,
      "relay received echo: got '" .. tostring(reply) .. "' expected '" .. tostring(data) .. "'")

    local ok2, serr2 = udp.send(client_sock, host, port, reply)
    if not ok2 then
      io.stderr:write("RELAY: send to client failed: " .. tostring(serr2) .. "\n")
    else
      print("RELAY: replied to client " .. host .. ":" .. port)
    end
  end

  udp.close(client_sock)
  udp.close(peer_sock)
  print("RELAY: done")
end)

-- ── Coroutine 3: Client ───────────────────────────────────────────────────
lunet.spawn(function()
  lunet.sleep(0.2) -- let peer + relay bind first

  local h, err = udp.bind(PEER_HOST, 0)
  assert(h, err)
  print("CLIENT: bound (ephemeral)")

  local payload = "hello"
  local ok, serr = udp.send(h, PEER_HOST, RELAY_CLIENT_PORT, payload)
  assert(ok, serr)
  print("CLIENT: sent '" .. payload .. "'")

  local reply, rhost, rport = udp.recv(h)
  check(reply == payload,
    "client roundtrip: got '" .. tostring(reply) .. "' expected '" .. payload .. "'")
  check(rhost == PEER_HOST,
    "client reply from correct host: " .. tostring(rhost))
  print("CLIENT: got reply '" .. tostring(reply) .. "' from " .. tostring(rhost) .. ":" .. tostring(rport))

  -- Send two more to verify sequential relay works
  for i, pl in ipairs({"world", "lunet"}) do
    ok, serr = udp.send(h, PEER_HOST, RELAY_CLIENT_PORT, pl)
    assert(ok, serr)
    print("CLIENT: sent #" .. (i + 1) .. " '" .. pl .. "'")

    reply = udp.recv(h)
    check(reply == pl,
      "client roundtrip #" .. (i + 1) .. ": got '" .. tostring(reply) .. "' expected '" .. pl .. "'")
  end

  udp.close(h)
  print("CLIENT: done")

  -- Report and exit
  print(failures > 0 and ("\n=== " .. failures .. "/" .. checks .. " FAILURES ===")
    or ("\n=== all " .. checks .. " checks passed ==="))
  os.exit(failures > 0 and 1 or 0)
end)
