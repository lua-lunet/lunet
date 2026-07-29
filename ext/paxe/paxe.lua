-- lunet.paxe: Lua-facing API for the lunet-paxe Rust cdylib (item07),
-- loaded through the LuaJIT FFI (the same model as ext/jsonic/jsonic.lua).
--
-- PAXE is the datagram encryption extension specified in PAXE.md: per-link
-- 32-byte shared keys addressed by (peer node id, epoch), AES-256-GCM
-- frames in two modes (standard below 64-byte payloads, DEK at and
-- above), selected automatically.
--
-- ERROR CONVENTION (uniform, documented in PAXE.md):
--   * Malformed arguments RAISE a Lua error — they are bugs in the
--     calling script. This covers wrong Lua types (checked here) and
--     out-of-range / constraint-violating values (checked in Rust, where
--     the message names the constraint: node id 0-65535, epoch 0-31,
--     channels 1-99 reserved, key exactly 32 bytes).
--   * Operational failures return nil, message — conditions the script
--     handles: not initialised, AES-GCM unavailable, no key installed,
--     payload over the mode maximum, keystore at capacity.
--   * open() is special: EVERY frame-level failure returns nil plus ONE
--     opaque message ("lunet.paxe: frame rejected"). The rejection
--     reason is never surfaced — a receiver that explains why a forgery
--     failed is a decryption oracle (PAXE.md "Failure Handling").
--
-- NO PANIC GUARANTEE: the cdylib is built panic = "abort", so a Rust
-- panic would kill this process. Every value crossing the boundary is
-- validated on BOTH sides: types here (LuaJIT would otherwise convert
-- silently), ranges and lengths in Rust. Ids/epochs cross as uint32 so
-- out-of-range values reach the Rust checks untruncated; this module
-- guarantees the conversion is exact (integer within uint32).
--
-- ITEM09: protected UDP sockets are HERE — paxe.protect / unprotect /
-- is_protected below, wired in THIS Lua layer by intercepting the
-- lunet.udp module table (the recorded integration decision is in the
-- comment block above the protect section). set_enabled/is_enabled
-- deliberately do NOT exist: the old module's process-global switch
-- printed "enabled" while protecting nothing, and one global flag cannot
-- express a process serving both an encrypted cluster port and an
-- unencrypted local port. Per-socket protect is the only enable
-- mechanism, so there is no precedence question to document. Statistics
-- counters (paxe.stats) and the failure policy (paxe.set_fail_policy)
-- landed with item08 below; the plaintext drop has its own counter
-- (rx_plaintext) from item09.
--
-- KEY MATERIAL: all keys live in the Rust keystore (guarded, mlocked,
-- zeroed-on-drop libsodium allocations). The 32-byte string passed to
-- keystore_set transits the Lua VM unguarded — see PAXE.md "Lua API"
-- for the honest statement of that limitation.

local ffi = require("ffi")

ffi.cdef[[
  const char* lunet_paxe_version(void);
  uint32_t lunet_paxe_overhead_standard(void);
  uint32_t lunet_paxe_overhead_dek(void);
  uint32_t lunet_paxe_max_payload_standard(void);
  uint32_t lunet_paxe_max_payload_dek(void);
  int lunet_paxe_init(void);
  int lunet_paxe_set_local_id(uint32_t node_id);
  int lunet_paxe_keystore_set(uint32_t peer, uint32_t epoch, const uint8_t* key, size_t key_len);
  int lunet_paxe_keystore_retire(uint32_t peer, uint32_t epoch);
  int lunet_paxe_keystore_clear(void);
  int lunet_paxe_seal(const uint8_t* payload, size_t payload_len, uint32_t to_id, uint32_t channel,
                      uint8_t* out, size_t out_cap, size_t* out_len);
  int lunet_paxe_open(const uint8_t* frame, size_t frame_len,
                      uint8_t* out, size_t out_cap, size_t* out_len,
                      uint32_t* from_id, uint32_t* channel, uint32_t* mode);
  int lunet_paxe_frame_for_us(const uint8_t* frame, size_t frame_len);
  uint32_t lunet_paxe_stats(uint64_t* out, size_t out_cap);
  int lunet_paxe_fail_policy_set(const uint8_t* name, size_t name_len);
  void lunet_paxe_shutdown(void);
  const uint8_t* lunet_paxe_last_error(size_t* len);
]]

-- Return codes, mirroring src/lib.rs.
local RC_OK = 0          -- success
local RC_OK_ABSENT = 1   -- success: retire addressed an absent slot
local RC_ERR = -1        -- operational failure -> nil, last_error()
local RC_INVAL = -2      -- malformed argument -> raise last_error()
local RC_DROP = -3       -- open rejected the frame -> nil, opaque message

-- THE single open() failure message (decryption-oracle avoidance). Never
-- differentiate it, never include the frame or a reason in it.
local OPEN_REJECTED = "lunet.paxe: frame rejected"

local function find_lib()
  local env = os.getenv("LUNET_PAXE_LIB")
  if env and env ~= "" then return env end
  local suffix, prefix = "so", "lib"
  if package.config:sub(1, 1) == "\\" then
    -- Windows: the cdylib is lunet_paxe.dll (no "lib" prefix)
    suffix, prefix = "dll", ""
  else
    local ok_popen, uname = pcall(io.popen, "uname -s 2>/dev/null")
    if ok_popen and uname then
      local sys = uname:read("*l") or ""
      uname:close()
      if sys == "Darwin" then suffix = "dylib" end
    end
  end
  local script = debug.getinfo(2, "S").source
  local dir = script:match("^@(.+)/[^/]+$") or "."
  for _, p in ipairs({
    dir .. "/target/release/" .. prefix .. "lunet_paxe." .. suffix,
    dir .. "/" .. prefix .. "lunet_paxe." .. suffix,
  }) do
    local f = io.open(p, "rb")
    if f then f:close(); return p end
  end
  error("lunet.paxe: cannot find " .. prefix .. "lunet_paxe." .. suffix, 3)
end

-- Loaded eagerly at require: the protocol constants below are read from
-- the cdylib at load time (single source of truth — they are NOT
-- restated as literals here), so the library must be present either way.
local C = ffi.load(find_lib())

local M = {}

-- Constants, computed by the Rust codec/standard/dek layers. The deleted
-- C hard-coded 36 and 82 in a #define and in the docs and both were
-- wrong; these can never drift from the implementation.
M.OVERHEAD_STANDARD = tonumber(C.lunet_paxe_overhead_standard())   -- 37
M.OVERHEAD_DEK = tonumber(C.lunet_paxe_overhead_dek())             -- 83
M.MAX_PAYLOAD_STANDARD = tonumber(C.lunet_paxe_max_payload_standard()) -- 65470
M.MAX_PAYLOAD_DEK = tonumber(C.lunet_paxe_max_payload_dek())       -- 65424

-- Reused out-boxes. Single-threaded VM, no yield across an FFI call.
local len_box = ffi.new("size_t[1]")
local from_box = ffi.new("uint32_t[1]")
local chan_box = ffi.new("uint32_t[1]")
local mode_box = ffi.new("uint32_t[1]")

local function last_error()
  local p = C.lunet_paxe_last_error(len_box)
  if p == nil then return "lunet.paxe: unknown error" end
  return ffi.string(p, tonumber(len_box[0]))
end

-- Dispatch a non-zero return code: RC_INVAL raises (a bug in the calling
-- script — error level 3 lands on the caller of the public function),
-- RC_ERR returns nil, message (a condition the script handles).
local function check_rc(rc)
  local msg = last_error()
  if rc == RC_INVAL then error(msg, 3) end
  return nil, msg
end

-- Type checks run HERE: by the time a value crosses the FFI its Lua type
-- is invisible to Rust. Range checks run in Rust (single source for the
-- constraint messages); this helper only guarantees the uint32
-- conversion is exact so out-of-range values reach those checks
-- untruncated.
local function check_uint32(v, name)
  if type(v) ~= "number" or v ~= v or v % 1 ~= 0 or v < 0 or v > 4294967295 then
    error(("bad argument '%s' (expected an integer between 0 and 4294967295, got %s)")
      :format(name, tostring(v)), 3)
  end
  return v
end

local function check_string(v, name)
  if type(v) ~= "string" then
    error(("bad argument '%s' (string expected, got %s)"):format(name, type(v)), 3)
  end
  return v
end

--- Crate version string.
function M.version()
  return ffi.string(C.lunet_paxe_version())
end

--- Initialise the module: libsodium + the AES-256-GCM hardware
--- requirement. Idempotent. Returns true, or nil, message when this
--- host/libsodium build lacks the hardware path (PAXE cannot operate).
function M.init()
  local rc = C.lunet_paxe_init()
  if rc ~= RC_OK then return check_rc(rc) end
  return true
end

-- Whether set_local_id has configured the module through THIS loader
-- (the FFI store is per-process and this module is its only client, so
-- the mirror is exact). protect() refuses to arm a socket while the
-- module is unconfigured — otherwise every datagram would drop silently.
local configured = false

--- Configure this node's identity — ONCE. node_id must fit u16
--- (0-65535). A second call without an intervening shutdown() raises:
--- silently re-creating the keystore would erase installed keys.
--- Returns true.
function M.set_local_id(node_id)
  node_id = check_uint32(node_id, "node_id")
  local rc = C.lunet_paxe_set_local_id(node_id)
  if rc ~= RC_OK then return check_rc(rc) end
  configured = true
  return true
end

--- Install the 32-byte key shared with `peer` (0-65535) under `epoch`
--- (0-31). Overwriting an occupied slot erases the old key. The key
--- string is copied into guarded Rust memory during the call and never
--- retained here. Returns true, or nil, message (not configured,
--- keystore at capacity, secure-memory failure).
function M.keystore_set(peer, epoch, key)
  peer = check_uint32(peer, "peer")
  epoch = check_uint32(epoch, "epoch")
  key = check_string(key, "key")
  local rc = C.lunet_paxe_keystore_set(peer, epoch, key, #key)
  if rc ~= RC_OK then return check_rc(rc) end
  return true
end

--- Retire one (peer, epoch) slot, erasing its key. Returns true if a key
--- was retired, false if the slot was empty, or nil, message when the
--- module is not configured.
function M.keystore_retire(peer, epoch)
  peer = check_uint32(peer, "peer")
  epoch = check_uint32(epoch, "epoch")
  local rc = C.lunet_paxe_keystore_retire(peer, epoch)
  if rc == RC_OK_ABSENT then return false end
  if rc ~= RC_OK then return check_rc(rc) end
  return true
end

--- Erase every installed key. Always succeeds (a no-op when
--- unconfigured). Returns true.
function M.keystore_clear()
  C.lunet_paxe_keystore_clear()
  return true
end

--- Seal `payload` (string) for `to_id` on `channel`. The frame's fromId
--- is the configured local id; the mode is selected by payload size
--- (standard below 64 bytes, DEK at and above); the send epoch is the
--- NEWEST epoch installed for to_id (installing a new epoch switches
--- senders to it — PAXE.md "Rotation"). channel must fit u16 and must
--- not be in the reserved system range 1-99 (application channels start
--- at 100; channel 0 is permitted). Returns the frame string, or nil,
--- message (not configured, no key for the peer, payload over the
--- selected mode's maximum, crypto failure).
function M.seal(payload, to_id, channel)
  payload = check_string(payload, "payload")
  to_id = check_uint32(to_id, "to_id")
  channel = check_uint32(channel, "channel")
  -- The buffer is sized for the LARGER overhead so this module needs no
  -- mode knowledge; Rust writes the actual frame length to len_box.
  local cap = #payload + M.OVERHEAD_DEK
  local out = ffi.new("uint8_t[?]", cap > 0 and cap or 1)
  local rc = C.lunet_paxe_seal(payload, #payload, to_id, channel, out, cap, len_box)
  if rc ~= RC_OK then return check_rc(rc) end
  return ffi.string(out, tonumber(len_box[0]))
end

--- Open one received `frame` (string). On success returns the payload
--- string, the authenticated from_id, the channel, and the mode as a
--- string ("standard" or "dek"). On ANY failure — malformed, unknown
--- key, authentication, unconfigured — returns nil plus the ONE opaque
--- message OPEN_REJECTED: the reason is deliberately never surfaced.
function M.open(frame)
  frame = check_string(frame, "frame")
  local cap = #frame
  local out = ffi.new("uint8_t[?]", cap > 0 and cap or 1)
  local rc = C.lunet_paxe_open(frame, #frame, out, cap, len_box, from_box, chan_box, mode_box)
  if rc == RC_DROP then return nil, OPEN_REJECTED end
  if rc ~= RC_OK then return check_rc(rc) end
  local mode = tonumber(mode_box[0]) == 1 and "dek" or "standard"
  return ffi.string(out, tonumber(len_box[0])), tonumber(from_box[0]), tonumber(chan_box[0]), mode
end

--- Shut the module down: every key is zeroed and freed and the local
--- identity is forgotten. Afterwards set_local_id() may configure
--- afresh. Idempotent. The statistics counters are NOT reset (they are
--- cumulative for the process lifetime); the log-once memo is.
function M.shutdown()
  C.lunet_paxe_shutdown()
  configured = false
end

-- ── item08: statistics counters and the failure policy ─────────────────

-- Counter names in the EXACT order the Rust snapshot writes them
-- (stats::Stats::fields, pinned by a Rust unit test). stats() asserts
-- the count matches, so a drift fails loudly here, never silently.
local STAT_FIELDS = {
  "rx_total", "rx_ok",
  "rx_plaintext", "rx_short", "rx_bad_flags", "rx_len_mismatch", "rx_no_peer",
  "rx_no_epoch", "rx_dek_len_mismatch", "rx_auth_fail",
  "tx_total", "tx_standard", "tx_dek", "tx_oversize",
}

--- Snapshot of the process-global cumulative counters, as a plain table
--- of numbers. Because open() never reveals WHY a frame was rejected
--- (decryption-oracle avoidance), these counters are the only diagnostic
--- channel: rx_total must always equal rx_ok plus the sum of the seven
--- rx_ reject reasons. The counters NEVER reset while the process lives —
--- measure DELTAS: snapshot before and after the window of interest;
--- never assert an absolute value.
function M.stats()
  local n = tonumber(C.lunet_paxe_stats(nil, 0))
  assert(n == #STAT_FIELDS, "lunet.paxe: stats field count drift between Rust and Lua")
  local buf = ffi.new("uint64_t[?]", n)
  C.lunet_paxe_stats(buf, n)
  local t = {}
  for i = 1, n do
    t[STAT_FIELDS[i]] = tonumber(buf[i - 1])
  end
  return t
end

-- Policy spellings accepted by set_fail_policy (case-insensitive on
-- input; the canonical forms are passed to Rust).
local POLICIES = { silent = "silent", log_once = "log_once", verbose = "verbose" }

--- Select the drop logging policy (PAXE.md "Failure Handling"):
---   "silent"   drop and count only (the default);
---   "log_once" the first drop of each kind writes one "[PAXE]" stderr
---              line per window, repeats are counted silently;
---   "verbose"  every drop writes a line.
--- Returns true when the policy was set, false for anything else
--- (unknown spelling or a non-string argument).
function M.set_fail_policy(name)
  if type(name) ~= "string" then return false end
  local canonical = POLICIES[name:lower()]
  if not canonical then return false end
  return C.lunet_paxe_fail_policy_set(canonical, #canonical) == RC_OK
end

-- ── item09: protected UDP sockets ──────────────────────────────────────
--
-- INTEGRATION LAYER (recorded decision): protection is wired HERE, in
-- Lua, by intercepting the lunet.udp module table — NOT in src/udp.c.
--  * The Rust core is already reachable from Lua through this FFI loader;
--    wiring udp.c would need a new C ABI into Rust AND would link the
--    cdylib into lunet-run, which is deliberately NOT linked (PAXE is a
--    pure opt-in extension).
--  * udp.c's recv callback runs on the libuv loop, not a Lua coroutine —
--    exactly the context the project notes (AGENTS.md) document for
--    use-after-free crashes (dangling lua_State* in long-lived handles,
--    registry ops on ctx->co). No crypto or key material goes near it.
--  * require("lunet.udp") returns a plain Lua table of C functions
--    (luaL_newlib), so interception needs NO C change: src/udp.c is
--    untouched, and unprotected sockets pay only one table lookup.
--
-- DECRYPTION TIME (recorded decision): DELIVERY-time, when Lua calls
-- udp.recv — not arrival-time in the libuv callback. Consequences,
-- accepted deliberately:
--  * The C receive queue holds CIPHERTEXT, never plaintext: no opened
--    payload lingers in C memory between arrival and recv, and no key
--    material is needed at queue-drain time.
--  * A close-flush (udp.close draining its queue) discards ciphertext
--    that was never authenticated — uncounted, because it never reached
--    the gate below. That is the same end state as a drop, for frames
--    that were undeliverable anyway (the socket is closing).
--  * The trade-off accepted: crypto work happens per recv call in
--    coroutine context rather than per arrival in the event loop — which
--    is also where Lua errors can be raised safely.
--
-- TRACING: no parallel mechanism is invented here. Datagram arrival is
-- already visible through udp.c's UDP_TRACE_RX in trace builds; every
-- drop below (plaintext gate or open rejection) is counted in Rust and
-- flows through the item08 failure policy — silent / log_once / verbose
-- "[PAXE] drop: <reason>" lines — exactly like a synchronous paxe.open.

local udp_mod -- the shared lunet.udp module table, captured on first protect
local raw_send, raw_recv, raw_close
-- sock (lightuserdata udp handle) -> { peer = ..., channel = ... }.
-- Weak KEYS so a forgotten handle cannot pin its config; close (wrapped
-- below) also clears the entry, because a freed ctx pointer can be
-- reused by a later bind and must never inherit stale protection.
local protected = setmetatable({}, { __mode = "k" })

local function protected_send(sock, host, port, data, peer, channel)
  local cfg = protected[sock]
  if cfg == nil then return raw_send(sock, host, port, data) end
  -- Destination peer and channel: the send call overrides the socket's
  -- configured values; both resolutions are explicit (item09). seal()
  -- raises on malformed overrides (a bug in the calling script).
  if peer == nil then peer = cfg.peer end
  if channel == nil then channel = cfg.channel end
  local frame, err = M.seal(data, peer, channel)
  if frame == nil then
    -- Operational failure (unconfigured, no key for the peer, or an
    -- oversized payload — the message names the selected mode's maximum
    -- and tx_oversize was counted in Rust): the send FAILS with a clear
    -- error and NOTHING is transmitted. Never truncated, never raw.
    return nil, err
  end
  return raw_send(sock, host, port, frame)
end

local function protected_recv(sock)
  if protected[sock] == nil then return raw_recv(sock) end
  while true do
    local data, host, port = raw_recv(sock)
    if data == nil then
      -- Closed or errored while waiting: pass the failure through
      -- unchanged (nil, nil, message) so scripts see a dead socket, not
      -- a silent hang.
      return data, host, port
    end
    -- The explicit plaintext gate FIRST: a datagram that is not a PAXE
    -- frame addressed to this node (under the 9-byte prefix, or a toId
    -- that is not us) is dropped and counted as rx_plaintext in Rust —
    -- by the addressing check, NEVER by the flags byte, which crafted
    -- plaintext could pass.
    if C.lunet_paxe_frame_for_us(data, #data) == 1 then
      local plain, from_id, channel = M.open(data)
      if plain ~= nil then
        -- plaintext + the authenticated fromId and channel; host/port
        -- stay transport-level metadata, exactly as raw recv reports
        -- them.
        return plain, host, port, from_id, channel
      end
      -- Rejected: the reason counter already moved inside Rust. Deliver
      -- NOTHING — no data, no error indicator (decryption-oracle
      -- avoidance) — and wait for the next datagram.
    end
  end
end

local function protected_close(sock)
  protected[sock] = nil -- see the weak-table note above
  return raw_close(sock)
end

-- Intercept the shared lunet.udp module table exactly once. From then
-- on every send/recv/close checks the protected registry first;
-- unprotected sockets pass straight through to the raw C functions.
local function wrap_udp()
  if udp_mod then return end
  udp_mod = require("lunet.udp")
  raw_send, raw_recv, raw_close = udp_mod.send, udp_mod.recv, udp_mod.close
  udp_mod.send = protected_send
  udp_mod.recv = protected_recv
  udp_mod.close = protected_close
end

local function check_u16(v, name)
  if type(v) ~= "number" or v ~= v or v % 1 ~= 0 or v < 0 or v > 65535 then
    error(("bad argument '%s' (expected an integer between 0 and 65535, got %s)")
      :format(name, tostring(v)), 3)
  end
  return v
end

--- Opt ONE UDP socket into PAXE protection (per-socket decision — there
--- is deliberately no process-global switch: a global cannot express
--- mixed encrypted/unencrypted traffic, and with one mechanism there is
--- no precedence question).
---
--- `sock` is a handle from udp.bind(). `config` is a table:
---   peer    (required) the PAXE node id this socket seals for and
---           expects frames from — the PAXE identity of the remote end,
---           independent of the IP address sent to (the frame's
---           authenticated toId is what protects against misdelivery).
---   channel (optional, default 0) the channel outgoing datagrams are
---           sealed on; 1-99 are reserved system channels.
---
--- After protect():
---   udp.send(sock, host, port, data [, peer [, channel]])
---       seals data for the peer on the channel (call-site values
---       override the configured ones) and transmits the frame. A seal
---       failure (unconfigured, no key, oversized payload) fails the
---       send with a clear error; nothing is transmitted.
---   udp.recv(sock) -> data, host, port, from_id, channel
---       returns the opened plaintext plus the AUTHENTICATED fromId and
---       channel. Datagrams that fail the plaintext gate or open() are
---       dropped and counted in Rust; NOTHING reaches Lua for them.
---   udp.close(sock)  also removes the protection entry.
---
--- Raises (a bug in the calling script) on a non-handle socket, a
--- non-table config, an out-of-range peer/channel, or when the module
--- is not configured (set_local_id first) — arming an unconfigured
--- socket would silently drop every datagram. Returns true.
function M.protect(sock, config)
  if type(sock) ~= "userdata" then
    error(("bad argument 'sock' (udp handle expected, got %s)"):format(type(sock)), 2)
  end
  if type(config) ~= "table" then
    error(("bad argument 'config' (table expected, got %s)"):format(type(config)), 2)
  end
  if not configured then
    error("lunet.paxe: local node id not configured: call set_local_id() before protect()", 2)
  end
  local peer = check_u16(config.peer, "config.peer")
  local channel = config.channel
  if channel == nil then channel = 0 end
  channel = check_u16(channel, "config.channel")
  if channel >= 1 and channel <= 99 then
    error(("bad argument 'config.channel' (channel %d is reserved: 1-99 are system channels, "
      .. "application channels start at 100)"):format(channel), 2)
  end
  wrap_udp()
  protected[sock] = { peer = peer, channel = channel }
  return true
end

--- Remove protection from a socket (idempotent). Subsequent send/recv on
--- it pass through to raw lunet.udp behaviour. Returns true.
function M.unprotect(sock)
  protected[sock] = nil
  return true
end

--- Is this socket protected? Returns false, or true plus the configured
--- peer and channel.
function M.is_protected(sock)
  local cfg = protected[sock]
  if cfg == nil then return false end
  return true, cfg.peer, cfg.channel
end

return M
