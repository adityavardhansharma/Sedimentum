#ifndef SEDIMENTUM_H
#define SEDIMENTUM_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Every call returns an sdm_status. On failure, sdm_last_error() returns a
 * short, thread-local description of the last error on this thread.
 * Handles are thread-safe: many threads may share one.
 * Buffers returned by sdm_get and sdm_scan_prefix belong to the caller and
 * must be released with sdm_free(ptr, len). */
typedef enum {
    SDM_OK = 0,
    SDM_NOT_FOUND = 1,
    SDM_CONFLICT = 2,
    SDM_LOCKED = 3,
    SDM_CORRUPT = 4,
    SDM_INVALID_ARGUMENT = 5,
    SDM_IO_ERROR = 6,
    SDM_OUT_OF_MEMORY = 7,
    SDM_POISONED = 8
} sdm_status;

typedef void sdm_db;

const char *sdm_last_error(void);

/* sync_writes != 0 makes every successful write durable (the default). */
sdm_status sdm_open(const char *path, size_t path_len, int sync_writes, sdm_db **out);
void sdm_close(sdm_db *db);

sdm_status sdm_put(sdm_db *db, const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len);
sdm_status sdm_put_ttl(sdm_db *db, const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len, uint32_t ttl_seconds);
/* Compare-and-swap. expected_seq == 0 means the key must not exist. */
sdm_status sdm_put_if(sdm_db *db, const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len, uint64_t expected_seq);
sdm_status sdm_seq_of(sdm_db *db, const uint8_t *key, size_t key_len, uint64_t *out_seq);
sdm_status sdm_delete(sdm_db *db, const uint8_t *key, size_t key_len);
sdm_status sdm_delete_prefix(sdm_db *db, const uint8_t *prefix, size_t prefix_len, uint64_t *out_count);
sdm_status sdm_get(sdm_db *db, const uint8_t *key, size_t key_len, uint8_t **out_value, size_t *out_len);
void sdm_free(uint8_t *ptr, size_t len);
sdm_status sdm_sync(sdm_db *db);
uint64_t sdm_count(sdm_db *db);

/* Up to `limit` pairs under `prefix`, newest key first when reverse != 0.
 * The buffer holds repeated [u32 key_len][key][u32 value_len][value]
 * (little endian). */
sdm_status sdm_scan_prefix(sdm_db *db, const uint8_t *prefix, size_t prefix_len, int reverse, size_t limit,
                           uint8_t **out_buf, size_t *out_len, size_t *out_count);

#ifdef __cplusplus
}
#endif
#endif
