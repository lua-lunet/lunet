# PAXE: Packet Encryption Extension Module

PAXE (Packet Encryption) is a secure packet encryption extension for Lunet, designed for applications that need to handle peer-to-peer encryption/decryption at the application level.

## Architecture

PAXE is an **extension module** that:
- Requires **libsodium** for cryptographic operations
- Uses **AES-256-GCM** for authenticated encryption
- Supports both standard and DEK (Data Encryption Key) modes
- Performs **in-place decryption** to minimize memory copying
- Provides native **Lua bindings** for easy integration

```
App Layer (Lua)
    ↓ require("lunet.paxe")
PAXE Lua Bindings (C)
    ↓
PAXE Core (C)
    ↓
libsodium (AES-256-GCM)
```

## Building PAXE

### Prerequisites
- libsodium development headers (`libsodium-dev` on Linux, via Homebrew on macOS)
- LuaJIT and libuv (standard Lunet dependencies)

### Configuration and Build

```bash
# Install libsodium (macOS)
brew install libsodium

# Install libsodium (Linux)
apt-get install libsodium-dev

# Build PAXE extension module
xmake build lunet-paxe
```

### Build Artifacts
- Release: `build/macosx/arm64/release/lunet/paxe.so`
- Debug: `build/macosx/arm64/debug/lunet/paxe.so`

## Fail-Fast Dependency Checking

If libsodium is not available, the build will **fail at configuration time** with a clear error:

```bash
$ xmake build lunet-paxe
# ERROR: libsodium package not found
#   Install via: brew install libsodium (macOS)
#   Install via: apt-get install libsodium-dev (Linux)
#   Install via: vcpkg install libsodium (Windows)
```

## Lua API

```lua
local paxe = require("lunet.paxe")

-- Initialization
local ok, err = paxe.init()          -- Initialize PAXE + libsodium
paxe.shutdown()                       -- Cleanup

-- Enable/Disable
paxe.set_enabled(true)                -- Enable encryption
local enabled = paxe.is_enabled()     -- Check if enabled

-- Key Management (keys must be exactly 32 bytes)
local ok, err = paxe.keystore_set(key_id, key_string)
paxe.keystore_clear()                 -- Wipe all keys securely

-- Failure Policy: "DROP", "LOG_ONCE", or "VERBOSE"
paxe.set_fail_policy("DROP")

-- Encryption (standard mode)
local ciphertext, err = paxe.encrypt(plaintext, key_id)

-- Decryption
local plaintext, key_id, flags = paxe.try_decrypt(ciphertext)
-- Returns nil, error_string on failure

-- Statistics
local stats = paxe.stats()
-- stats.rx_total, stats.rx_ok, stats.rx_auth_fail, etc.

-- Constants
paxe.OVERHEAD_STANDARD  -- 36 bytes (header + nonce + tag)
paxe.OVERHEAD_DEK       -- 82 bytes (DEK mode overhead)
paxe.VERSION            -- Module version string
```

## C API

### Initialization
```c
int paxe_init(void);                    // Initialize PAXE + libsodium
void paxe_shutdown(void);                // Cleanup
int paxe_is_enabled(void);               // Check if enabled
void paxe_set_enabled(int enabled);      // Enable/disable
```

### Key Management
```c
int paxe_keystore_set(uint32_t key_id, const uint8_t key[32]);
int paxe_keystore_clear(void);           // Wipe keys from memory
```

### Packet Operations
```c
ssize_t paxe_try_decrypt(uint8_t *buf, size_t len,
                         uint32_t *out_key_id,
                         uint8_t *out_flags);
// Returns: plaintext length on success, -1 on failure
// Decrypts in-place, moving plaintext to start of buffer
```

### Statistics & Policy
```c
typedef struct {
    uint64_t rx_total;          // Total packets received
    uint64_t rx_ok;             // Successfully decrypted
    uint64_t rx_short;          // Packet too short
    uint64_t rx_len_mismatch;   // Length mismatch
    uint64_t rx_no_key;         // Key not found
    uint64_t rx_auth_fail;      // Authentication failed
    uint64_t rx_reserved_nonzero;
} paxe_stats_t;

void paxe_stats_get(paxe_stats_t *out);
void paxe_set_fail_policy(paxe_fail_policy_t policy);  // DROP, LOG_ONCE, VERBOSE
```

## Packet Format

### Standard Mode (AES-256-GCM)
```
Header (8) | Nonce (12) | Ciphertext+Tag (N+16)
```

### DEK Mode (with Data Encryption Key)
```
Header (8) | KEK_Nonce (12) | Enc_DEK (32) | DEK_Nonce (12) | DEK_Len (2) | Ciphertext+Tag (N+16)
```

## Examples

See the `examples/` directory for working code:

- **`examples/06_paxe_encryption.lua`** - Complete API walkthrough with round-trip encryption/decryption
- **`examples/07_paxe_stress.lua`** - Stress test with configurable iterations, packet size, and key count

### Quick Start

```lua
local paxe = require("lunet.paxe")

-- Initialize
paxe.init()

-- Set up a key (32 bytes required)
paxe.keystore_set(1, string.rep("K", 32))

-- Encrypt
local ciphertext = paxe.encrypt("Hello, PAXE!", 1)

-- Decrypt
local plaintext, key_id, flags = paxe.try_decrypt(ciphertext)
print(plaintext)  -- "Hello, PAXE!"

-- Cleanup
paxe.keystore_clear()
paxe.shutdown()
```

## Testing

### Run Examples
```bash
# Run the encryption demo
./build/macosx/arm64/release/lunet-run examples/06_paxe_encryption.lua

# Run stress test (1000 iterations default)
./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua
```

### Stress Testing
```bash
# High-volume test
ITERATIONS=10000 PACKET_SIZE=1500 NUM_KEYS=256 \
  ./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua
```

### With Tracing
```bash
# Build with verbose tracing
xmake f -c -y --lunet_trace=y --lunet_verbose_trace=y
xmake build lunet-paxe

# Run with stderr logging
./build/macosx/arm64/debug/lunet-run examples/06_paxe_encryption.lua 2>&1 | grep PAXE
```

## Performance

Benchmarks (macOS arm64, Apple Silicon, release build):
- Throughput: ~400,000 ops/sec (encrypt + decrypt cycles)
- Bandwidth: ~400 MB/sec (1KB packets)
- Overhead: 36 bytes per packet (standard mode)
- Hardware AES-256-GCM acceleration

## Security Considerations

1. **Key Derivation**: Keys must be 32 bytes (256-bit). Derive from secrets using a KDF (HKDF, Argon2).
2. **Nonce Handling**: PAXE generates random 12-byte nonces per packet via libsodium.
3. **Authentication**: Failed decryption is always dropped (no oracle attacks).
4. **Key Wiping**: `keystore_clear()` uses `sodium_memzero()` to prevent key recovery.
5. **Policy-Based Logging**: Use `LOG_ONCE` to detect attacks without noise.

## Build Flags

| Flag | Purpose | When to Use |
|------|---------|------------|
| `LUNET_PAXE` | Enable PAXE compilation | Always (set by xmake target) |
| `LUNET_TRACE` | Debug tracing + counters | Development/debugging |
| `LUNET_TRACE_VERBOSE` | Per-event stderr logging | Detailed debugging |

## Limitations

- **Single-Threaded**: Keystore is not thread-safe. Protect with locks if needed.
- **No Key Rotation API**: Clear and re-add keys for rotation.
- **No Compression**: PAXE is encryption-only. Combine with other modules for compression.

## Future Enhancements

- [ ] Per-peer key rotation with versioning
- [ ] Hardware AES detection + fallback
- [ ] ChaCha20-Poly1305 support (alternative to AES-GCM)
- [ ] Perfetto tracing integration

## References

- libsodium: https://doc.libsodium.org/
- AES-256-GCM: https://en.wikipedia.org/wiki/Galois/Counter_Mode
- Lunet Architecture: See README.md and AGENTS.md
