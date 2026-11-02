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
    SDM_POISONED = 8,
    /* The engine behind this handle has no such operation. */
    SDM_UNSUPPORTED = 9
} sdm_status;

typedef void sdm_db;

const char *sdm_last_error(void);

/* sync_writes != 0 makes every successful write durable (the default). */
sdm_status sdm_open(const char *path, size_t path_len, int sync_writes, sdm_db **out);
/* Like sdm_open, but once the in-memory index passes memory_budget bytes,
   entries for older data move to an index file on disk. 0 means no limit. */
sdm_status sdm_open_capped(const char *path, size_t path_len, int sync_writes, size_t memory_budget, sdm_db **out);
/* Opens with a chosen engine: 1 = v1 (one in-memory index), 2 = v2
   (stream store with a write-ahead log), 3 = v3 (lean stream store).
   0 picks whatever the directory already holds, or v1 for a new one.
   Every function below works on every engine unless it says otherwise. */
sdm_status sdm_open_engine(const char *path, size_t path_len, int engine, int sync_writes, sdm_db **out);
/* 1, 2 or 3. */
int sdm_engine(sdm_db *db);
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
/* v1 keeps a running count; v2 and v3 count by walking every key. */
uint64_t sdm_count(sdm_db *db);

/* v2 and v3 only (v1 returns SDM_UNSUPPORTED): */
/* Atomically adds delta to the decimal integer at key (missing = 0). */
sdm_status sdm_incr(sdm_db *db, const uint8_t *key, size_t key_len, int64_t delta, int64_t *out_value);
/* Keeps the first (keep_last == 0) or last `keep` keys under prefix and
   deletes the rest. */
sdm_status sdm_trim(sdm_db *db, const uint8_t *prefix, size_t prefix_len, size_t keep, int keep_last, uint64_t *out_deleted);
/* Writes a consistent copy into dest, a directory that must not exist. */
sdm_status sdm_backup(sdm_db *db, const char *dest, size_t dest_len);
/* Checks every stored checksum; SDM_CORRUPT if any fails. */
sdm_status sdm_verify(sdm_db *db);

/* Up to `limit` pairs under `prefix`, newest key first when reverse != 0.
 * The buffer holds repeated [u32 key_len][key][u32 value_len][value]
 * (little endian). */
sdm_status sdm_scan_prefix(sdm_db *db, const uint8_t *prefix, size_t prefix_len, int reverse, size_t limit,
                           uint8_t **out_buf, size_t *out_len, size_t *out_count);

#ifdef __cplusplus
}
#endif
#endif
