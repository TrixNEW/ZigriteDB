#ifndef ZIGRITEDB_H
#define ZIGRITEDB_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* ABI 3 stores format 2 worlds; format 1 worlds open with ZG_NEEDS_MIGRATION. */
#define ZG_ABI_VERSION 3u
#define ZG_MAX_PATH_LENGTH 4096u
#define ZG_MAX_BATCH_RECORDS 4096u
#define ZG_MAX_GROUP_BATCHES 64u
#define ZG_MAX_READ_BATCH 256u
#define ZG_MAX_BATCH_BYTES (64u * 1024u * 1024u)
#define ZG_MAX_VALUE_SIZE (16u * 1024u * 1024u)
#define ZG_ALL_COMPONENTS 0xffffffffu

typedef struct zg_handle zg_handle;
enum zg_status {
    ZG_OK, ZG_NOT_FOUND, ZG_INVALID_ARGUMENT, ZG_BUFFER_TOO_SMALL,
    ZG_OUT_OF_MEMORY, ZG_UNSUPPORTED, ZG_CORRUPTION, ZG_IO_ERROR,
    ZG_NEEDS_RECOVERY, ZG_BUSY, ZG_BATCH_ORDER, ZG_LIMIT, ZG_CLEANUP_PENDING, ZG_PERMISSION_DENIED,
    ZG_NO_SPACE, ZG_READ_ONLY, ZG_NEEDS_MIGRATION
};
enum zg_operation_kind { ZG_PUT, ZG_DELETE };
enum zg_durability { ZG_SYNC, ZG_BUFFERED };
/* Components are Bedrock chunk record tags; any value 0..255 is accepted. */
enum zg_component {
    ZG_DATA3D = 0x2b, ZG_VERSION = 0x2c, ZG_DATA2D = 0x2d, ZG_DATA2D_LEGACY = 0x2e,
    ZG_SUBCHUNK = 0x2f, ZG_LEGACY_TERRAIN = 0x30, ZG_BLOCK_ENTITIES = 0x31, ZG_ENTITIES = 0x32,
    ZG_PENDING_TICKS = 0x33, ZG_BIOME_STATE = 0x35, ZG_FINALIZED_STATE = 0x36, ZG_BORDER_BLOCKS = 0x38,
    ZG_RANDOM_TICKS = 0x3a, ZG_BLENDING_DATA = 0x40, ZG_ACTOR_DIGEST_VERSION = 0x41,
    ZG_LEGACY_VERSION = 0x76,
    ZG_ACTOR_DIGEST = 0x80 /* Bedrock's "digp" record, stored with its chunk */
};
typedef struct {
    uint32_t version, struct_size, max_open_shards, max_keys;
    uint32_t max_segments, batch_buffer_size;
    uint64_t max_segment_size;
    uint32_t buffered, compression_threshold; /* buffered defaults to 1; set 0 for synchronous writes. */
    /* Budget for cached values only; cache bookkeeping and allocator overhead are extra. */
    uint64_t cache_bytes;
    uint32_t cache_shards;
    uint32_t skip_unchanged;
    /* A region is compacted in the background once it holds compact_min_bytes and less than
       compact_live_percent of it is live. 0 percent turns this off. */
    uint64_t compact_min_bytes;
    uint32_t compact_live_percent;
    uint32_t reserved;
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
    uint64_t batch_id; /* 0 takes the region's next ID */
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
    uint32_t component;
    int32_t subchunk_y;
    size_t offset, length; /* the value is buffer[offset, offset + length) */
} zg_chunk_record;
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
/* Reads every record of a chunk. ZG_BUFFER_TOO_SMALL fills count and required for a retry;
   ZG_NOT_FOUND means the chunk has no records. */
int zg_get_chunk(zg_handle *handle, int32_t dimension, int32_t chunk_x, int32_t chunk_z, uint8_t *buffer, size_t capacity,
                 zg_chunk_record *records, size_t record_capacity, size_t *count, size_t *required);
int zg_flush(zg_handle *handle);
int zg_compact(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z);
int zg_last_batch_id(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z, uint64_t *out);
int zg_compact_async(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z);
int zg_prefetch(zg_handle *handle, const zg_key *keys, size_t count);
int zg_list_regions(zg_handle *handle, zg_region *out, size_t capacity, size_t *count);
int zg_list_keys(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z, uint32_t component,
                 zg_key *out, size_t capacity, size_t *count);
int zg_maintenance_wait(zg_handle *handle);
int zg_recover_region(const uint8_t *source, size_t source_len, const uint8_t *destination, size_t destination_len, const zg_options *options);
int zg_stats_get(zg_handle *handle, zg_stats *out);
int zg_stats_reset(zg_handle *handle);
#ifdef __cplusplus
}
#endif
#endif
