#ifndef ZIGRITEDB_H
#define ZIGRITEDB_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define ZG_ABI_VERSION 1u
#define ZG_MAX_PATH_LENGTH 4096u
#define ZG_MAX_BATCH_RECORDS 4096u
#define ZG_MAX_GROUP_BATCHES 64u
/* Includes the bytes used by each record header and checksum. */
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
/* Start with zg_options_init. Set compression_threshold to 0 to turn compression off. */
typedef struct {
    uint32_t version, struct_size, max_open_shards, max_keys;
    uint32_t max_segments, batch_buffer_size;
    uint64_t max_segment_size;
    uint32_t buffered, compression_threshold;
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

/* The message belongs to the library. Do not free it. */
const char *zg_status_message(int status);
uint32_t zg_abi_version(void);
/* Returns 1 if storage is supported on this platform, or 0 if not. */
int zg_platform_supported(void);
/* Leaves out unchanged on error. Use subchunk_y = 0 unless the component is a subchunk. */
int zg_key_init(zg_key *out, int32_t dimension, int32_t chunk_x, int32_t chunk_z, uint32_t component, int32_t subchunk_y);
int zg_key_validate(const zg_key *key);
/* Finds the 32x32 region. Leaves out unchanged if the key is invalid. */
int zg_key_region(const zg_key *key, zg_region *out);
int zg_options_init(zg_options *options);
int zg_options_validate(const zg_options *options);
/* The directory must already exist. Pass the path length without a trailing NUL. */
int zg_open(const uint8_t *path, size_t path_len, const zg_options *options, zg_handle **out);
/* Calls may overlap. Wait for them before close, which frees the handle even on error. */
int zg_close(zg_handle *handle);
/* Keep each batch in one region. Use a higher batch ID for each write to that region. */
int zg_write(zg_handle *handle, uint64_t batch_id, const zg_operation *operations, size_t count);
/* One region, increasing IDs, at most 4096 records total. Success always syncs.
   Each batch is atomic; an error can leave earlier batches applied. */
int zg_write_group(zg_handle *handle, const zg_batch *batches, size_t count);
/* Pass your own buffer. required gives the value size even when the buffer is too small. */
int zg_get(zg_handle *handle, const zg_key *key, uint8_t *output, size_t capacity, size_t *required);
/* Buffered writes reach disk after a successful flush, shard eviction, or close. */
int zg_flush(zg_handle *handle);
int zg_compact(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z);
/* Resume batch IDs after reopen. Coordinate values here are region coordinates. */
int zg_last_batch_id(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z, uint64_t *out);
/* Queues one region. Returns ZG_BUSY for duplicates or a full 16-slot queue. */
int zg_compact_async(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z);
/* Drains queued work and reports its first error. Close also drains the queue. */
int zg_maintenance_wait(zg_handle *handle);
/* Copies committed data to an empty directory. Leaves the source untouched. */
int zg_recover_region(const uint8_t *source, size_t source_len, const uint8_t *destination, size_t destination_len, const zg_options *options);
#ifdef __cplusplus
}
#endif
#endif
