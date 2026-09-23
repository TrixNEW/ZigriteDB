#ifndef ZIGRITEDB_H
#define ZIGRITEDB_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define ZG_ABI_VERSION 2u
#define ZG_MAX_PATH_LENGTH 4096u
#define ZG_MAX_BATCH_RECORDS 4096u
#define ZG_MAX_GROUP_BATCHES 64u
#define ZG_MAX_READ_BATCH 256u
#define ZG_MAX_BATCH_BYTES (64u * 1024u * 1024u)
#define ZG_MAX_VALUE_SIZE (16u * 1024u * 1024u)

typedef struct zg_handle zg_handle;
enum zg_status {
    ZG_OK, ZG_NOT_FOUND, ZG_INVALID_ARGUMENT, ZG_BUFFER_TOO_SMALL,
    ZG_OUT_OF_MEMORY, ZG_UNSUPPORTED, ZG_CORRUPTION, ZG_IO_ERROR,
    ZG_NEEDS_RECOVERY, ZG_BUSY, ZG_BATCH_ORDER, ZG_LIMIT, ZG_CLEANUP_PENDING, ZG_PERMISSION_DENIED,
    ZG_NO_SPACE, ZG_READ_ONLY
};
enum zg_operation_kind { ZG_PUT, ZG_DELETE };
enum zg_durability { ZG_SYNC, ZG_BUFFERED };
enum zg_component {
    ZG_SUBCHUNK, ZG_BIOMES, ZG_BLOCK_ENTITIES, ZG_ENTITIES, ZG_HEIGHTMAP, ZG_METADATA
};
typedef struct {
    uint32_t version, struct_size, max_open_shards, max_keys;
    uint32_t max_segments, batch_buffer_size;
    uint64_t max_segment_size;
    uint32_t buffered, compression_threshold;
    /* Budget for cached values only; cache bookkeeping and allocator overhead are extra. */
    uint64_t cache_bytes;
    uint32_t cache_shards;
    uint32_t skip_unchanged;
} zg_options;
typedef struct {
    int32_t dimension, chunk_x, chunk_z, subchunk_y;
    uint32_t component;
} zg_key;
typedef struct {
    int32_t dimension, x, z;
} zg_region;
typedef struct {
    zg_key key;
    uint32_t remove;
    const uint8_t *value;
    size_t value_len;
} zg_operation;
typedef struct {
    uint64_t batch_id;
    const zg_operation *operations;
    size_t count;
} zg_batch;
typedef struct {
    zg_key key;
    uint8_t *output;
    size_t capacity;
} zg_read_request;
typedef struct {
    int status;
    size_t required;
} zg_read_result;
typedef struct {
    uint64_t get_calls, writes, records_written;
    uint64_t raw_bytes_written, compressed_bytes_written;
    uint64_t disk_reads, bytes_read;
    uint64_t fsync_count, fsync_duration_ns;
    uint64_t segment_rotations;
    uint64_t compactions, compaction_input_bytes, compaction_output_bytes, compaction_duration_ns;
    uint64_t recovery_attempts, recovery_errors;
    uint64_t cache_hits, cache_misses, cache_evictions;
    uint64_t unchanged_write_skips;
} zg_stats;

const char *zg_status_message(int status);
uint32_t zg_abi_version(void);
int zg_platform_supported(void);
int zg_key_init(zg_key *out, int32_t dimension, int32_t chunk_x, int32_t chunk_z, uint32_t component, int32_t subchunk_y);
int zg_key_validate(const zg_key *key);
int zg_key_region(const zg_key *key, zg_region *out);
int zg_options_init(zg_options *options);
int zg_options_validate(const zg_options *options);
int zg_open(const uint8_t *path, size_t path_len, const zg_options *options, zg_handle **out);
int zg_close(zg_handle *handle);
int zg_write(zg_handle *handle, uint64_t batch_id, const zg_operation *operations, size_t count);
int zg_write_group(zg_handle *handle, const zg_batch *batches, size_t count);
int zg_get(zg_handle *handle, const zg_key *key, uint8_t *output, size_t capacity, size_t *required);
int zg_get_many(zg_handle *handle, const zg_read_request *requests, zg_read_result *results, size_t count);
int zg_flush(zg_handle *handle);
int zg_compact(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z);
int zg_last_batch_id(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z, uint64_t *out);
int zg_compact_async(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z);
int zg_prefetch(zg_handle *handle, const zg_key *keys, size_t count);
int zg_list_regions(zg_handle *handle, zg_region *out, size_t capacity, size_t *count);
int zg_list_keys(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z, uint32_t components,
                 zg_key *out, size_t capacity, size_t *count);
int zg_maintenance_wait(zg_handle *handle);
int zg_recover_region(const uint8_t *source, size_t source_len, const uint8_t *destination, size_t destination_len, const zg_options *options);
int zg_stats_get(zg_handle *handle, zg_stats *out);
int zg_stats_reset(zg_handle *handle);
#ifdef __cplusplus
}
#endif
#endif
