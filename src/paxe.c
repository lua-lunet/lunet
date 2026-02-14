#include "paxe.h"
#include <sodium.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "lunet_mem.h"

/* Constants */
#define HEADER_LEN 8
#define NONCE_LEN 12
#define TAG_LEN 16
#define DEK_KEY_LEN 32
#define DEK_NONCE_LEN 12
#define DEK_LEN_FIELD_LEN 2
/* Encrypted DEK is just the 32 bytes of key material (stream cipher encrypted) */
#define ENC_DEK_LEN 32 

#define FLAG_DEK_MODE 0x01

/* Overhead calculation
 * Standard: Header(8) + Nonce(12) + Tag(16) = 36
 * DEK: Header(8) + KEK_Nonce(12) + Enc_DEK(32) + DEK_Nonce(12) + DEK_Len(2) + Tag(16) = 82
 */
#define OVERHEAD_STD 36
#define OVERHEAD_DEK 82

/* Globals */
static int g_paxe_enabled = 0;
static paxe_fail_policy_t g_fail_policy = PAXE_DROP;
static paxe_stats_t g_stats = {0};
static uint32_t g_log_once_mask = 0;

/* Key Store: Simple Open Addressing Hash Table */
#define KEYSTORE_SIZE 256
typedef struct {
    uint32_t key_id;
    uint8_t key[32];
    int valid;
} keystore_entry_t;

static keystore_entry_t g_keystore[KEYSTORE_SIZE];

/* Helper: Read Big-Endian integers */
static uint16_t read_u16be(const uint8_t *p) {
    return (uint16_t)((p[0] << 8) | p[1]);
}

static uint32_t read_u32be(const uint8_t *p) {
    return (uint32_t)((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]);
}

/* API Implementation */

int paxe_init(void) {
    if (sodium_init() < 0) {
        return -1;
    }
    if (crypto_aead_aes256gcm_is_available() != 1) {
        return -2; /* Available but hardware support check failed? Or just not implemented? 
                      Actually sodium_init usually sets things up, 
                      but checking aes256gcm availability is required by design. */
    }
    memset(&g_stats, 0, sizeof(g_stats));
    memset(g_keystore, 0, sizeof(g_keystore));
    g_log_once_mask = 0;
    return 0;
}

void paxe_shutdown(void) {
    paxe_keystore_clear();
}

int paxe_is_enabled(void) {
    return g_paxe_enabled;
}

void paxe_set_enabled(int enabled) {
    g_paxe_enabled = enabled;
}

/* Keystore Implementation */
int paxe_keystore_set(uint32_t key_id, const uint8_t key[32]) {
    /* Simple linear probe */
    uint32_t idx = key_id % KEYSTORE_SIZE;
    int start_idx = idx;

    /* First pass: look for update */
    do {
        if (g_keystore[idx].valid && g_keystore[idx].key_id == key_id) {
            memcpy(g_keystore[idx].key, key, 32);
            return 0;
        }
        idx = (idx + 1) % KEYSTORE_SIZE;
    } while (idx != start_idx);

    /* Second pass: look for empty slot */
    idx = start_idx;
    do {
        if (!g_keystore[idx].valid) {
            g_keystore[idx].key_id = key_id;
            memcpy(g_keystore[idx].key, key, 32);
            g_keystore[idx].valid = 1;
            return 0;
        }
        idx = (idx + 1) % KEYSTORE_SIZE;
    } while (idx != start_idx);

    return -1; /* Full */
}

int paxe_keystore_clear(void) {
    for (int i = 0; i < KEYSTORE_SIZE; i++) {
        if (g_keystore[i].valid) {
            sodium_memzero(g_keystore[i].key, 32);
            g_keystore[i].valid = 0;
        }
    }
    return 0;
}

static const uint8_t* keystore_get(uint32_t key_id) {
    uint32_t idx = key_id % KEYSTORE_SIZE;
    int start_idx = idx;
    do {
        if (g_keystore[idx].valid && g_keystore[idx].key_id == key_id) {
            return g_keystore[idx].key;
        }
        if (!g_keystore[idx].valid) break; /* Stop at hole? No, could be collision chain. 
                                              But for this simple impl, we stop at empty if we assume no deletes.
                                              If deletes were supported, we'd need tombstones.
                                              We don't support delete yet, only clear. */
        idx = (idx + 1) % KEYSTORE_SIZE;
    } while (idx != start_idx);
    return NULL;
}

void paxe_set_fail_policy(paxe_fail_policy_t policy) {
    g_fail_policy = policy;
}

void paxe_stats_get(paxe_stats_t *out) {
    *out = g_stats;
}

static uint32_t log_once_bit_for_reason(const char *reason) {
    if (reason == NULL) return 0;
    if (strcmp(reason, "packet too short") == 0) return 1u << 0;
    if (strcmp(reason, "reserved byte nonzero") == 0) return 1u << 1;
    if (strcmp(reason, "length mismatch") == 0) return 1u << 2;
    if (strcmp(reason, "dek length mismatch") == 0) return 1u << 3;
    if (strcmp(reason, "key not found") == 0) return 1u << 4;
    if (strcmp(reason, "auth failed") == 0) return 1u << 5;
    if (strcmp(reason, "dek decrypt error") == 0) return 1u << 6;
    return 0;
}

/* Helper to handle failure recording and policy */
static ssize_t handle_failure(const char *reason, uint64_t *counter) {
    if (counter) (*counter)++;
    PAXE_TRACE_DECRYPT_FAIL(reason);
    
    if (g_fail_policy == PAXE_DROP) {
        return -1;
    }
    /* If LOG_ONCE or VERBOSE, we might want to return error but the caller (udp.c) 
       interprets -1 as drop. 
       The design says: "return nothing to Lua at all... or deliver an error indicator".
       User choice: "should be a global policy... drop, or log once, or log verbosely".
       BUT the implementation plan said: "On failure: apply policy ... return -1".
       
       If we return -1, udp.c drops it.
       If we want to log, we should do it HERE (fprintf).
       
       We'll log to stderr based on policy here, then return -1 to drop.
       Wait, if the user wants "error indicator" delivered to Lua, we'd return a special code.
       But the user answer on clarification said: "log once should memoriase it has logged... verbose should log every failure".
       It didn't explicitly say "deliver error to Lua".
       The previous clarification option B was "deliver an error indicator so Lua can log".
       The user answered: "should be a global policy... log once... or log verbosely".
       This implies the LOGGING happens in C (to stderr/logs), not necessarily passing bad packets to Lua.
       Passing bad packets to Lua is dangerous (oracle).
       
       So we will log to stderr here and always return -1 (drop).
    */
    
    if (g_fail_policy == PAXE_VERBOSE) {
        fprintf(stderr, "[PAXE] Drop: %s\n", reason);
    } else if (g_fail_policy == PAXE_LOG_ONCE) {
        uint32_t bit = log_once_bit_for_reason(reason);
        if (bit == 0) bit = 1u << 31; /* unknown reason bucket */
        if ((g_log_once_mask & bit) == 0) {
            fprintf(stderr, "[PAXE] Drop (first occurrence): %s\n", reason);
            g_log_once_mask |= bit;
        }
    }
    
    return -1;
}

ssize_t paxe_try_decrypt(uint8_t *buf, size_t len, uint32_t *out_key_id, uint8_t *out_flags) {
    g_stats.rx_total++;

    /* 1. Basic length check */
    if (len < HEADER_LEN + NONCE_LEN + TAG_LEN) {
        return handle_failure("packet too short", &g_stats.rx_short);
    }

    /* 2. Parse Header */
    uint16_t declared_len = read_u16be(buf);
    uint8_t flags = buf[2];
    uint8_t reserved = buf[3];
    uint32_t key_id = read_u32be(buf + 4);

    if (reserved != 0) {
        return handle_failure("reserved byte nonzero", &g_stats.rx_reserved_nonzero);
    }

    if (out_key_id) *out_key_id = key_id;
    if (out_flags) *out_flags = flags;

    /* 3. Determine Mode and Expected Length */
    int is_dek = (flags & FLAG_DEK_MODE);
    size_t overhead = is_dek ? OVERHEAD_DEK : OVERHEAD_STD;
    
    if (len != declared_len + overhead) {
        return handle_failure("length mismatch", &g_stats.rx_len_mismatch);
    }

    /* 4. Get Key (KEK) */
    const uint8_t *kek = keystore_get(key_id);
    if (!kek) {
        return handle_failure("key not found", &g_stats.rx_no_key);
    }

    /* 5. Decrypt */
    unsigned long long plaintext_len;
    int ret;

    if (!is_dek) {
        /* Standard Mode
         * Packet: Header(8) | Nonce(12) | Ciphertext(...) | Tag(16)
         * AAD: Header(8)
         */
        uint8_t *nonce = buf + HEADER_LEN;
        uint8_t *ciphertext = buf + HEADER_LEN + NONCE_LEN;
        unsigned long long ciphertext_len = declared_len + TAG_LEN;

        /* In-place decrypt: ciphertext overwrites itself with plaintext */
        ret = crypto_aead_aes256gcm_decrypt(
            ciphertext, &plaintext_len,
            NULL,
            ciphertext, ciphertext_len,
            buf, HEADER_LEN, /* AAD is Header */
            nonce, kek
        );
        
        if (ret == 0) {
            if (plaintext_len != (unsigned long long)declared_len) {
                return handle_failure("length mismatch", &g_stats.rx_len_mismatch);
            }
            /* Move plaintext to start of buf */
            memmove(buf, ciphertext, plaintext_len);
        }

    } else {
        /* DEK Mode
         * Packet: Header(8) | KEK_Nonce(12) | Enc_DEK(32) | DEK_Nonce(12) | DEK_Len(2) | Ciphertext(...) | Tag(16)
         * AAD: Header(8) ? Or Header + DEK fields?
         * Design doc says: "If the existing Lua sketch uses 'header as AAD', then the entire 8-byte header... is the AAD."
         * It doesn't explicitly say the DEK fields are AAD.
         * BUT, the Payload Tag covers the Ciphertext.
         * If we want to bind the DEK to the payload, we should include the DEK fields in AAD.
         * HOWEVER, we must match the Sender implementation.
         * The Lua sketch `paxe.lua` (archived) handled only Standard Mode.
         * The Design Doc "Proposed PAXE framing" says:
         * "Header: 8 bytes (AAD; includes flags)"
         * "Header is 8 bytes... the entire 8-byte header... is the AAD."
         * It implies ONLY the 8-byte header is AAD.
         * 
         * DEK Decryption:
         * KEK_Nonce = buf + 8 (12 bytes)
         * Enc_DEK = buf + 20 (32 bytes)
         * DEK_Nonce = buf + 52 (12 bytes)
         * DEK_Len = buf + 64 (2 bytes) -- Ignored for now? declared_len from header is used.
         * Ciphertext = buf + 66
         */
        
        uint8_t *kek_nonce = buf + HEADER_LEN;
        uint8_t *enc_dek = buf + HEADER_LEN + NONCE_LEN;
        uint8_t *dek_nonce = enc_dek + ENC_DEK_LEN;
        uint8_t *ciphertext = dek_nonce + DEK_NONCE_LEN + DEK_LEN_FIELD_LEN;
        unsigned long long ciphertext_len = declared_len + TAG_LEN;
        uint16_t dek_len_field = read_u16be(dek_nonce + DEK_NONCE_LEN);

        uint8_t dek[DEK_KEY_LEN];
        if (dek_len_field != declared_len) {
            return handle_failure("dek length mismatch", &g_stats.rx_len_mismatch);
        }
        
        /* Decrypt DEK using KEK and KEK_Nonce via ChaCha20 stream XOR 
           (Assuming sender used crypto_stream_chacha20_ietf_xor)
        */
        if (crypto_stream_chacha20_ietf_xor(dek, enc_dek, ENC_DEK_LEN, kek_nonce, kek) != 0) {
             /* Should not fail unless params wrong */
             return handle_failure("dek decrypt error", &g_stats.rx_auth_fail);
        }
        
        /* Decrypt Payload using DEK and DEK_Nonce */
        ret = crypto_aead_aes256gcm_decrypt(
            ciphertext, &plaintext_len,
            NULL,
            ciphertext, ciphertext_len,
            buf, HEADER_LEN, /* AAD is Header */
            dek_nonce, dek
        );
        
        sodium_memzero(dek, sizeof(dek)); /* Clear DEK from stack */
        
        if (ret == 0) {
            if (plaintext_len != (unsigned long long)declared_len) {
                return handle_failure("length mismatch", &g_stats.rx_len_mismatch);
            }
            memmove(buf, ciphertext, plaintext_len);
        }
    }

    if (ret != 0) {
        return handle_failure("auth failed", &g_stats.rx_auth_fail);
    }

    g_stats.rx_ok++;
    PAXE_TRACE_DECRYPT_OK(key_id, plaintext_len);
    return (ssize_t)plaintext_len;
}

/* ============================================================================
 * Lua Bindings
 * ============================================================================ */

#include "lunet_lua.h"

/* paxe.init() -> boolean, string|nil */
static int l_paxe_init(lua_State *L) {
    int ret = paxe_init();
    if (ret == 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else if (ret == -1) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "sodium_init failed");
        return 2;
    } else {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "AES-256-GCM not available (no hardware support?)");
        return 2;
    }
}

/* paxe.shutdown() */
static int l_paxe_shutdown(lua_State *L) {
    (void)L;
    paxe_shutdown();
    return 0;
}

/* paxe.is_enabled() -> boolean */
static int l_paxe_is_enabled(lua_State *L) {
    lua_pushboolean(L, paxe_is_enabled());
    return 1;
}

/* paxe.set_enabled(boolean) */
static int l_paxe_set_enabled(lua_State *L) {
    int enabled = lua_toboolean(L, 1);
    paxe_set_enabled(enabled);
    return 0;
}

/* paxe.keystore_set(key_id, key_string) -> boolean, string|nil */
static int l_paxe_keystore_set(lua_State *L) {
    lua_Integer key_id = luaL_checkinteger(L, 1);
    size_t key_len;
    const char *key = luaL_checklstring(L, 2, &key_len);

    if (key_len != 32) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "key must be exactly 32 bytes");
        return 2;
    }

    int ret = paxe_keystore_set((uint32_t)key_id, (const uint8_t *)key);
    if (ret == 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "keystore full");
        return 2;
    }
}

/* paxe.keystore_clear() */
static int l_paxe_keystore_clear(lua_State *L) {
    (void)L;
    paxe_keystore_clear();
    return 0;
}

/* paxe.set_fail_policy(policy_string) -> boolean */
static int l_paxe_set_fail_policy(lua_State *L) {
    const char *policy_str = luaL_checkstring(L, 1);
    paxe_fail_policy_t policy;

    if (strcmp(policy_str, "DROP") == 0 || strcmp(policy_str, "drop") == 0) {
        policy = PAXE_DROP;
    } else if (strcmp(policy_str, "LOG_ONCE") == 0 || strcmp(policy_str, "log_once") == 0) {
        policy = PAXE_LOG_ONCE;
    } else if (strcmp(policy_str, "VERBOSE") == 0 || strcmp(policy_str, "verbose") == 0) {
        policy = PAXE_VERBOSE;
    } else {
        lua_pushboolean(L, 0);
        return 1;
    }

    paxe_set_fail_policy(policy);
    lua_pushboolean(L, 1);
    return 1;
}

/* paxe.stats() -> table */
static int l_paxe_stats(lua_State *L) {
    paxe_stats_t stats;
    paxe_stats_get(&stats);

    lua_createtable(L, 0, 7);

    lua_pushinteger(L, (lua_Integer)stats.rx_total);
    lua_setfield(L, -2, "rx_total");

    lua_pushinteger(L, (lua_Integer)stats.rx_ok);
    lua_setfield(L, -2, "rx_ok");

    lua_pushinteger(L, (lua_Integer)stats.rx_short);
    lua_setfield(L, -2, "rx_short");

    lua_pushinteger(L, (lua_Integer)stats.rx_len_mismatch);
    lua_setfield(L, -2, "rx_len_mismatch");

    lua_pushinteger(L, (lua_Integer)stats.rx_no_key);
    lua_setfield(L, -2, "rx_no_key");

    lua_pushinteger(L, (lua_Integer)stats.rx_auth_fail);
    lua_setfield(L, -2, "rx_auth_fail");

    lua_pushinteger(L, (lua_Integer)stats.rx_reserved_nonzero);
    lua_setfield(L, -2, "rx_reserved_nonzero");

    return 1;
}

/* paxe.try_decrypt(buffer_string) -> plaintext_string, key_id, flags | nil, error_string */
static int l_paxe_try_decrypt(lua_State *L) {
    size_t len;
    const char *input = luaL_checklstring(L, 1, &len);

    /* Make a mutable copy since paxe_try_decrypt modifies in-place */
    uint8_t *buf = lunet_alloc(len);
    if (!buf) {
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }
    memcpy(buf, input, len);

    uint32_t key_id = 0;
    uint8_t flags = 0;
    ssize_t plaintext_len = paxe_try_decrypt(buf, len, &key_id, &flags);

    if (plaintext_len < 0) {
        lunet_free_nonnull(buf);
        lua_pushnil(L);
        lua_pushstring(L, "decryption failed");
        return 2;
    }

    lua_pushlstring(L, (const char *)buf, (size_t)plaintext_len);
    lua_pushinteger(L, (lua_Integer)key_id);
    lua_pushinteger(L, (lua_Integer)flags);
    lunet_free_nonnull(buf);
    return 3;
}

/* paxe.encrypt(plaintext, key_id) -> ciphertext | nil, error
 * Standard mode encryption for testing/demos
 */
static int l_paxe_encrypt(lua_State *L) {
    size_t plaintext_len;
    const char *plaintext = luaL_checklstring(L, 1, &plaintext_len);
    lua_Integer key_id = luaL_checkinteger(L, 2);

    /* Get key from keystore */
    const uint8_t *key = keystore_get((uint32_t)key_id);
    if (!key) {
        lua_pushnil(L);
        lua_pushstring(L, "key not found");
        return 2;
    }

    /* Allocate output buffer: Header(8) + Nonce(12) + Ciphertext + Tag(16) */
    size_t ciphertext_len = plaintext_len + TAG_LEN;
    size_t total_len = HEADER_LEN + NONCE_LEN + ciphertext_len;
    uint8_t *buf = lunet_alloc(total_len);
    if (!buf) {
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }

    /* Build header */
    buf[0] = (plaintext_len >> 8) & 0xFF;  /* Length high byte */
    buf[1] = plaintext_len & 0xFF;          /* Length low byte */
    buf[2] = 0;                              /* Flags (standard mode) */
    buf[3] = 0;                              /* Reserved */
    buf[4] = (key_id >> 24) & 0xFF;
    buf[5] = (key_id >> 16) & 0xFF;
    buf[6] = (key_id >> 8) & 0xFF;
    buf[7] = key_id & 0xFF;

    /* Generate random nonce */
    uint8_t *nonce = buf + HEADER_LEN;
    randombytes_buf(nonce, NONCE_LEN);

    /* Encrypt */
    uint8_t *ciphertext = buf + HEADER_LEN + NONCE_LEN;
    unsigned long long actual_ciphertext_len;

    int ret = crypto_aead_aes256gcm_encrypt(
        ciphertext, &actual_ciphertext_len,
        (const uint8_t *)plaintext, plaintext_len,
        buf, HEADER_LEN,  /* AAD is header */
        NULL,
        nonce, key
    );

    if (ret != 0) {
        lunet_free_nonnull(buf);
        lua_pushnil(L);
        lua_pushstring(L, "encryption failed");
        return 2;
    }

    lua_pushlstring(L, (const char *)buf, total_len);
    lunet_free_nonnull(buf);
    return 1;
}

/* Module function table */
static const luaL_Reg paxe_funcs[] = {
    {"init", l_paxe_init},
    {"shutdown", l_paxe_shutdown},
    {"is_enabled", l_paxe_is_enabled},
    {"set_enabled", l_paxe_set_enabled},
    {"keystore_set", l_paxe_keystore_set},
    {"keystore_clear", l_paxe_keystore_clear},
    {"set_fail_policy", l_paxe_set_fail_policy},
    {"stats", l_paxe_stats},
    {"try_decrypt", l_paxe_try_decrypt},
    {"encrypt", l_paxe_encrypt},
    {NULL, NULL}
};

/* Module entry point */
int lunet_open_paxe(lua_State *L) {
    luaL_register(L, NULL, paxe_funcs);

    /* Add constants */
    lua_pushinteger(L, OVERHEAD_STD);
    lua_setfield(L, -2, "OVERHEAD_STANDARD");

    lua_pushinteger(L, OVERHEAD_DEK);
    lua_setfield(L, -2, "OVERHEAD_DEK");

    lua_pushstring(L, "1.0.0");
    lua_setfield(L, -2, "VERSION");

    return 1;
}
