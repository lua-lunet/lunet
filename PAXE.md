# PAXE: Packet Encryption Extension Module

PAXE (Packet Encryption) is a secure packet encryption extension for Lunet, designed for applications that need to handle peer-to-peer encryption/decryption at the application level.

## Architecture

PAXE is an **extension module** that:
- Requires **libsodium** for cryptographic operations
- Uses **AES-256-GCM** for authenticated encryption
- Supports both standard and DEK (Data Encryption Key) modes
- Performs **in-place decryption** to minimize memory copying
- Integrates with Lunet's coroutine-based async I/O

```
App Layer (Lua)
    ↓
Lunet UDP/Socket (C)
    ↓ (LUNET_PAXE gated)
PAXE Decryption (C)
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

# Configure Lunet with tracing (recommended for debugging)
xmake f -c -y --lunet_trace=y

# Build PAXE extension module
xmake build lunet-paxe
```

### Build Artifacts
- Debug: `build/macosx/arm64/debug/lunet/paxe.so` (~121 KB)
- Release: `build/macosx/arm64/release/lunet/paxe.so` (smaller, optimized)

## Fail-Fast Dependency Checking

If libsodium is not available, the build will **fail at configuration time** with a clear error:

```bash
$ xmake build lunet-paxe
# ERROR: libsodium package not found
#   Install via: brew install libsodium (macOS)
#   Install via: apt-get install libsodium-dev (Linux)
#   Install via: vcpkg install libsodium (Windows)
```

## API Overview

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

### Packet Decryption
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

## Integration with UDP

When `LUNET_PAXE` is enabled, applications can integrate PAXE into UDP receive callbacks:

```c
// In UDP receive callback
uint8_t buf[MAX_PKT_SIZE];
size_t len = /* filled by UDP */;

if (paxe_is_enabled()) {
    uint32_t key_id;
    uint8_t flags;
    ssize_t plaintext_len = paxe_try_decrypt(buf, len, &key_id, &flags);
    if (plaintext_len < 0) {
        // Policy already applied (DROP/LOG/VERBOSE)
        return;  // Packet dropped
    }
    len = plaintext_len;  // Use decrypted packet
}

// Continue with plaintext packet
```

## Examples

See the `examples/` directory for API previews and simulations:

- **`examples/06_paxe_encryption.lua`** - API walkthrough showing initialization, key management, policies, and statistics (simulation until Lua bindings added)
- **`examples/07_paxe_stress.lua`** - Stress test simulation for load testing packet processing loops

## Testing

### Run Examples
```bash
# Run the encryption demo (shows full API usage)
./build/macosx/arm64/release/lunet-run examples/06_paxe_encryption.lua

# Run stress test with default settings (100 packets)
./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua
```

### Stress Testing
```bash
# Simulate high-volume packet flow
ITERATIONS=10000 PACKET_SIZE=1500 NUM_KEYS=256 \
  ./build/macosx/arm64/release/lunet-run examples/07_paxe_stress.lua
```

### With Tracing
```bash
# Build with verbose tracing
xmake f -c -y --lunet_trace=y --lunet_verbose_trace=y
xmake build lunet-paxe

# Run examples with stderr logging
./build/macosx/arm64/debug/lunet-run examples/06_paxe_encryption.lua 2>&1 | grep PAXE_TRACE
```

## Performance

Benchmarks (macOS arm64, debug build with tracing):
- Packets/sec: ~1,000 pkt/s per core (in simulation)
- Memory overhead: ~121 KB module + ~4 KB runtime state
- CPU overhead: In-place AES-256-GCM (hardware accelerated)

## Security Considerations

1. **Key Derivation**: Keys must be 32 bytes (256-bit). Derive from secrets using a KDF.
2. **Nonce Handling**: PAXE generates random 12-byte nonces per packet. Ensure uniqueness.
3. **Authentication**: Failed decryption is always dropped (no oracle attacks).
4. **Key Wiping**: `paxe_keystore_clear()` uses `sodium_memzero()` to prevent key recovery.
5. **Policy-Based Logging**: Use `PAXE_LOG_ONCE` to detect attacks without noise.

## Build Flags

| Flag | Purpose | When to Use |
|------|---------|------------|
| `LUNET_PAXE` | Enable PAXE compilation | Always (set by xmake target) |
| `LUNET_TRACE` | Debug tracing + counters | Development/debugging |
| `LUNET_TRACE_VERBOSE` | Per-event stderr logging | Detailed debugging |

## Limitations

- **No Lua Bindings Yet**: PAXE is C-only. Use LuaJIT FFI to call the C API directly. See `examples/06_paxe_encryption.lua` for planned API design.
- **No Compression**: PAXE is encryption-only. Combine with other modules for compression.
- **Single-Threaded**: Keystore is not thread-safe. Protect with locks if needed.
- **No Key Rotation API**: Clear and re-add keys for rotation (planned enhancement).

## Future Enhancements

- [ ] Lua FFI bindings for direct Lua access
- [ ] Per-peer key rotation with versioning
- [ ] Hardware AES detection + fallback
- [ ] ChaCha20-Poly1305 support (alternative to AES-GCM)
- [ ] Perfetto tracing integration

## References

- libsodium: https://doc.libsodium.org/
- AES-256-GCM: https://en.wikipedia.org/wiki/Galois/Counter_Mode
- Lunet Architecture: See README.md and AGENTS.md
