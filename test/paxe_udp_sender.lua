-- item09 end-to-end test, SENDER side (PAXE node 100). Driven by
-- test/run_paxe_udp_e2e.sh, which starts it only after the receiver
-- (node 200) has signalled readiness. Covers the protected send path:
-- an oversized payload fails the send with a clear error (nothing is
-- transmitted, tx_oversize moves), then one sealed frame goes out to
-- the receiver's protected socket.
--
-- Loopback only (127.0.0.1), per the repository security rule.

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ext_dir = script_dir .. "/../ext/paxe"

local chunk, load_err = loadfile(ext_dir .. "/paxe.lua")
if not chunk then error("cannot load paxe.lua: " .. tostring(load_err)) end
local paxe = chunk()
local lunet = require("lunet")
local udp = require("lunet.udp")

local e2e_dir = os.getenv("LUNET_PAXE_E2E_DIR") or ".tmp/paxe-e2e"

local failures = 0
local checks = 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. msg)
  else
    print("   OK: " .. msg)
  end
end

local KEY = string.rep("\x42", 32)
local NODE_A, NODE_B, CHAN = 100, 200, 137
local PORT_A, PORT_B = 20412, 20411

local function main()
  print("=== paxe udp e2e: sender (node 100) ===")

  local init_ok, init_err = paxe.init()
  if not init_ok then
    print("SKIP: AES-256-GCM unavailable on this host: " .. tostring(init_err))
    os.exit(0)
  end
  assert(paxe.set_local_id(NODE_A))
  assert(paxe.keystore_set(NODE_B, 3, KEY))

  local sockA, aerr = udp.bind("127.0.0.1", PORT_A)
  assert(sockA, aerr)
  check(paxe.protect(sockA, { peer = NODE_B, channel = CHAN }) == true, "protect(sockA)")

  -- Oversized payload: the send FAILS with a clear error naming the
  -- selected mode's maximum; nothing is sealed or transmitted.
  local s0 = paxe.stats()
  local ok, err = udp.send(sockA, "127.0.0.1", PORT_B, string.rep("x", paxe.MAX_PAYLOAD_DEK + 1))
  check(ok == nil and type(err) == "string" and err:find("65424", 1, true) ~= nil,
    "oversized send fails with a clear error naming 65424")
  local s1 = paxe.stats()
  check(s1.tx_oversize == s0.tx_oversize + 1, "tx_oversize +1")
  check(s1.tx_total == s0.tx_total, "an oversized offer seals nothing")

  -- The protected send: 10 bytes -> standard mode (automatic selection).
  local sent, serr = udp.send(sockA, "127.0.0.1", PORT_B, "hello paxe")
  check(sent == true, "protected send succeeds: " .. tostring(serr))
  local s2 = paxe.stats()
  check(s2.tx_total == s1.tx_total + 1, "tx_total +1")
  check(s2.tx_standard == s1.tx_standard + 1 and s2.tx_dek == s1.tx_dek,
    "sub-threshold payload sealed standard (automatic mode selection)")

  assert(udp.close(sockA))
  paxe.shutdown()

  local df = assert(io.open(e2e_dir .. "/done", "w"))
  df:write(failures > 0 and "FAIL\n" or "PASS\n")
  df:close()

  print(failures > 0 and ("=== sender: " .. failures .. " FAILURES ===")
    or ("=== sender: all " .. checks .. " checks passed ==="))
  os.exit(failures > 0 and 1 or 0)
end

lunet.spawn(main)
