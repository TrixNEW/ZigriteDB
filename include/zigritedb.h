#ifndef ZIGRITEDB_H
#define ZIGRITEDB_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct zg_handle zg_handle;
enum zg_status {
    ZG_OK, ZG_NOT_FOUND, ZG_INVALID_ARGUMENT, ZG_BUFFER_TOO_SMALL,
    ZG_OUT_OF_MEMORY, ZG_UNSUPPORTED, ZG_CORRUPTION, ZG_IO_ERROR,
    ZG_NEEDS_RECOVERY, ZG_BUSY, ZG_BATCH_ORDER, ZG_LIMIT, ZG_CLEANUP_PENDING
};
enum zg_component {
    ZG_SUBCHUNK, ZG_BIOMES, ZG_BLOCK_ENTITIES, ZG_ENTITIES, ZG_HEIGHTMAP, ZG_METADATA
};
/* Initialize options with zg_options_init; a zero compression threshold disables compression. */
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
    zg_key key;
    uint32_t remove;
    const uint8_t *value;
    size_t value_len;
} zg_operation;

int zg_options_init(zg_options *options);
/* Paths name existing directories. Strings are length-delimited, without NUL. */
int zg_open(const uint8_t *path, size_t path_len, const zg_options *options, zg_handle **out);
/* Calls on a handle are serialized. Close consumes it, even on failure; do not race close. */
int zg_close(zg_handle *handle);
/* All operations must share a region. Batch IDs increase independently per region. */
int zg_write(zg_handle *handle, uint64_t batch_id, const zg_operation *operations, size_t count);
/* required receives the value size, also on BUFFER_TOO_SMALL. Buffers belong to the caller. */
int zg_get(zg_handle *handle, const zg_key *key, uint8_t *output, size_t capacity, size_t *required);
/* Buffered writes are durable only after a successful flush, eviction, or close. */
int zg_flush(zg_handle *handle);
int zg_compact(zg_handle *handle, int32_t dimension, int32_t region_x, int32_t region_z);
/* Copies a region's committed data to an empty destination; preserves the source. */
int zg_recover_region(const uint8_t *source, size_t source_len, const uint8_t *destination, size_t destination_len, const zg_options *options);
#ifdef __cplusplus
}
#endif
#endif
