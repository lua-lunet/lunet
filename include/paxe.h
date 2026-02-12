#ifndef PAXE_H
#define PAXE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/* Failure policies */
typedef enum { 
    PAXE_DROP, 
    PAXE_LOG_ONCE, 
    PAXE_VERBOSE 
} paxe_fail_policy_t;

/* Initialization / Shutdown */
int  paxe_init(void);
void paxe_shutdown(void);
int  paxe_is_enabled(void);
void paxe_set_enabled(int enabled);

/* Key management */
int  paxe_keystore_set(uint32_t key_id, const uint8_t key[32]);
int  paxe_keystore_clear(void);
void paxe_set_fail_policy(paxe_fail_policy_t policy);

/* Core decryption 
 * Returns: plaintext length on success, -1 on failure.
 * Mutates buf in-place.
 */
ssize_t paxe_try_decrypt(uint8_t *buf, size_t len, 
                         uint32_t *out_key_id, 
                         uint8_t *out_flags);

/* Statistics */
typedef struct {
    uint64_t rx_total;
    uint64_t rx_ok;
    uint64_t rx_short;
    uint64_t rx_len_mismatch;
    uint64_t rx_no_key;
    uint64_t rx_auth_fail;
    uint64_t rx_reserved_nonzero;
} paxe_stats_t;

void paxe_stats_get(paxe_stats_t *out);

/* Tracing macros (zero-cost in release) */
#ifdef LUNET_TRACE
#include <stdio.h>
#define PAXE_TRACE_DECRYPT_OK(key_id, len) \
    fprintf(stderr, "[PAXE_TRACE] DECRYPT OK key=%u len=%zu\n", (key_id), (size_t)(len))
#define PAXE_TRACE_DECRYPT_FAIL(reason) \
    fprintf(stderr, "[PAXE_TRACE] DECRYPT FAIL: %s\n", (reason))
#else
#define PAXE_TRACE_DECRYPT_OK(key_id, len) ((void)0)
#define PAXE_TRACE_DECRYPT_FAIL(reason) ((void)0)
#endif

#endif // PAXE_H
