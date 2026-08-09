---@meta

---@class lunet.paxe.config
---@field peer integer PAXE node id this socket seals for and expects frames from (0-65535)
---@field channel integer? Channel outgoing datagrams are sealed on (default 0); 1-99 are reserved

---@class lunet.paxe.stats
---@field rx_total integer Frames offered to open()
---@field rx_ok integer Frames opened and authenticated
---@field rx_plaintext integer Dropped by the plaintext gate
---@field rx_short integer Dropped: shorter than the minimum frame
---@field rx_bad_flags integer Dropped: flags byte failed the bit1=0/bit2=1 check
---@field rx_len_mismatch integer Dropped: header length disagreed with the datagram
---@field rx_no_peer integer Dropped: no key installed for the frame's fromId
---@field rx_no_epoch integer Dropped: no key installed for the frame's key epoch
---@field rx_dek_len_mismatch integer Dropped: DEK-mode inner length disagreed
---@field rx_auth_fail integer Dropped: AES-256-GCM authentication failed
---@field tx_total integer Frames sealed
---@field tx_standard integer Frames sealed in standard mode
---@field tx_dek integer Frames sealed in DEK mode
---@field tx_oversize integer Seals refused: payload over the mode maximum

---@class lunet.paxe
---PAXE (Packet Encryption) — AES-256-GCM authenticated datagram encryption.
---
---Implemented as a zero-dependency Rust cdylib (`ext/paxe`) loaded over LuaJIT
---FFI; it is not linked into `lunet-run`. Requires libsodium with a hardware
---AES-256-GCM path — `init()` reports a plain error where that is unavailable.
---
---Keys are addressed by `(peer, epoch)`, never by a bare key id, and are held
---in guarded, locked, zero-on-drop memory owned by Rust. Call `set_local_id()`
---once before installing keys or protecting sockets.
local paxe = {}

---Standard-mode frame overhead in bytes (header + flags + nonce + tag).
---Read from the cdylib at load time, so it can never drift from the codec.
---@type integer
paxe.OVERHEAD_STANDARD = nil

---DEK-mode frame overhead in bytes.
---@type integer
paxe.OVERHEAD_DEK = nil

---Largest payload sealable in standard mode.
---@type integer
paxe.MAX_PAYLOAD_STANDARD = nil

---Largest payload sealable in DEK mode.
---@type integer
paxe.MAX_PAYLOAD_DEK = nil

---Crate version string.
---@return string version
function paxe.version() end

---Initialize libsodium and assert the AES-256-GCM hardware requirement.
---Idempotent.
---@return true|nil ok `true` on success
---@return string|nil error Message when this host/libsodium build has no hardware AES path
---@usage
---```lua
---local paxe = require("lunet.paxe")
---local ok, err = paxe.init()
---if not ok then error(err) end
---paxe.set_local_id(7)
---```
function paxe.init() end

---Configure this node's identity. Call ONCE; a second call without an
---intervening `shutdown()` raises, because silently re-creating the keystore
---would erase installed keys.
---@param node_id integer This node's PAXE id (0-65535)
---@return true|nil ok
---@return string|nil error
function paxe.set_local_id(node_id) end

---Install the 32-byte key shared with `peer` under `epoch`. Overwriting an
---occupied slot erases the old key. The key is copied into guarded Rust memory
---during the call and never retained on the Lua side.
---@param peer integer Peer node id (0-65535)
---@param epoch integer Key epoch (0-31)
---@param key string Exactly 32 bytes
---@return true|nil ok
---@return string|nil error Not configured, keystore at capacity, or secure-memory failure
function paxe.keystore_set(peer, epoch, key) end

---Retire one `(peer, epoch)` slot, erasing its key.
---@param peer integer Peer node id (0-65535)
---@param epoch integer Key epoch (0-31)
---@return boolean|nil retired `true` if a key was retired, `false` if the slot was empty
---@return string|nil error Set when the module is not configured
function paxe.keystore_retire(peer, epoch) end

---Erase every installed key. A no-op when unconfigured.
---@return true ok
function paxe.keystore_clear() end

---Seal `payload` for `to_id` on `channel`. The frame's fromId is the configured
---local id; the mode is chosen by payload size (standard below 64 bytes, DEK at
---and above); the send epoch is the newest epoch installed for `to_id`.
---@param payload string Data to seal
---@param to_id integer Destination node id (0-65535)
---@param channel integer Channel (u16); 1-99 are reserved system channels
---@return string|nil frame The sealed frame, or nil on error
---@return string|nil error Not configured, no key for the peer, payload oversized, or crypto failure
function paxe.seal(payload, to_id, channel) end

---Open one received frame. On ANY failure — malformed, unknown key,
---authentication, unconfigured — returns nil plus a single opaque message; the
---reason is deliberately never surfaced (decryption-oracle avoidance). Use
---`stats()` deltas for diagnostics.
---@param frame string The received frame
---@return string|nil payload Decrypted payload, or nil on rejection
---@return integer|string from_id Authenticated sender node id, or the opaque error message
---@return integer|nil channel Authenticated channel
---@return string|nil mode `"standard"` or `"dek"`
function paxe.open(frame) end

---Shut the module down: every key is zeroed and freed and the local identity is
---forgotten. `set_local_id()` may configure afresh afterwards. Idempotent.
---Statistics counters are NOT reset; the log-once memo is.
function paxe.shutdown() end

---Snapshot the process-global cumulative counters. Counters never reset while
---the process lives — measure DELTAS, never assert an absolute value.
---`rx_total` always equals `rx_ok` plus the sum of the seven `rx_` reject reasons.
---@return lunet.paxe.stats stats
function paxe.stats() end

---Select the drop logging policy.
---@param name string `"silent"` (default), `"log_once"`, or `"verbose"` (case-insensitive)
---@return boolean ok `false` for an unknown spelling or a non-string argument
function paxe.set_fail_policy(name) end

---Opt one UDP socket into PAXE protection. There is deliberately no
---process-global switch. After this call, `udp.send(sock, host, port, data [,
---peer [, channel]])` seals before transmitting, and `udp.recv(sock)` returns
---`data, host, port, from_id, channel` with the authenticated fromId and
---channel. Datagrams that fail the plaintext gate or `open()` are dropped and
---counted in Rust; nothing reaches Lua for them. `udp.close(sock)` also removes
---the protection entry.
---
---Raises on a non-handle socket, a non-table config, an out-of-range
---peer/channel, or when the module is not configured.
---@param sock userdata UDP handle from `udp.bind()`
---@param config lunet.paxe.config
---@return true ok
---@usage
---```lua
---local udp = require("lunet.udp")
---local paxe = require("lunet.paxe")
---paxe.init()
---paxe.set_local_id(1)
---paxe.keystore_set(2, 0, key32)
---local sock = udp.bind("127.0.0.1", 9000)
---paxe.protect(sock, { peer = 2, channel = 100 })
---udp.send(sock, "127.0.0.1", 9001, "hello")
---local data, host, port, from_id, channel = udp.recv(sock)
---```
function paxe.protect(sock, config) end

---Remove protection from a socket (idempotent). Subsequent send/recv pass
---through to raw `lunet.udp` behaviour.
---@param sock userdata UDP handle
---@return true ok
function paxe.unprotect(sock) end

---Is this socket protected?
---@param sock userdata UDP handle
---@return boolean protected
---@return integer|nil peer Configured peer node id when protected
---@return integer|nil channel Configured channel when protected
function paxe.is_protected(sock) end

return paxe
