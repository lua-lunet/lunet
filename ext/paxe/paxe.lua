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
-- NOT HERE YET: set_enabled/is_enabled arrive with item09, when they
-- genuinely control transport protection. The old module exposed the
-- switch as a no-op and an example printed that it worked; that defect
-- is not being repeated. Counters/stats arrive with item08; UDP socket
-- integration with item09.
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

--- Configure this node's identity — ONCE. node_id must fit u16
--- (0-65535). A second call without an intervening shutdown() raises:
--- silently re-creating the keystore would erase installed keys.
--- Returns true.
function M.set_local_id(node_id)
  node_id = check_uint32(node_id, "node_id")
  local rc = C.lunet_paxe_set_local_id(node_id)
  if rc ~= RC_OK then return check_rc(rc) end
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
--- afresh. Idempotent.
function M.shutdown()
  C.lunet_paxe_shutdown()
end

return M
