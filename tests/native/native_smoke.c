#include "zigritedb.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    assert(strcmp(zg_status_message(ZG_BUFFER_TOO_SMALL), "Buffer too small") == 0);
    assert(strcmp(zg_status_message(-1), "Unknown status") == 0);
    assert(zg_abi_version() == ZG_ABI_VERSION);
    assert(zg_platform_supported() == 1);
    assert(strcmp(zg_status_message(ZG_PERMISSION_DENIED), "Permission denied") == 0);
    zg_key key;
    assert(zg_key_init(&key, 1, -32, 64, ZG_SUBCHUNK, -4) == ZG_OK);
    assert(key.dimension == 1 && key.chunk_x == -32 && key.chunk_z == 64 && key.subchunk_y == -4);
    assert(zg_key_init(&key, 0, 0, 0, ZG_METADATA, 1) == ZG_INVALID_ARGUMENT);
    assert(key.component == ZG_SUBCHUNK && key.subchunk_y == -4);
    assert(zg_key_init(&key, 0, 0, 0, UINT32_MAX, 0) == ZG_INVALID_ARGUMENT);
    assert(zg_key_validate(&key) == ZG_OK);
    assert(zg_key_validate(NULL) == ZG_INVALID_ARGUMENT);
    zg_region region;
    key.chunk_x = -33;
    assert(zg_key_region(&key, &region) == ZG_OK);
    assert(region.dimension == 1 && region.x == -2 && region.z == 2);
    key.component = UINT32_MAX;
    assert(zg_key_validate(&key) == ZG_INVALID_ARGUMENT);
    assert(zg_key_region(&key, &region) == ZG_INVALID_ARGUMENT);
    assert(region.dimension == 1 && region.x == -2 && region.z == 2);
    zg_options options;
    assert(zg_options_init(&options) == ZG_OK);
    assert(zg_options_validate(&options) == ZG_OK);
    assert(zg_options_validate(NULL) == ZG_INVALID_ARGUMENT);
    options.buffered = 2;
    assert(zg_options_validate(&options) == ZG_INVALID_ARGUMENT);
    options.buffered = ZG_SYNC;
    assert(strcmp(zg_status_message(ZG_NO_SPACE), "Disk full or quota exceeded") == 0);
    assert(strcmp(zg_status_message(ZG_READ_ONLY), "Read-only filesystem") == 0);
    assert(options.version == zg_abi_version() && options.struct_size == sizeof(options));
    assert(options.buffered == ZG_SYNC);
    options.buffered = ZG_BUFFERED;
    options.batch_buffer_size = 4096;
    options.max_segment_size = 4096;
    zg_handle *handle = NULL;
    assert(zg_open((uint8_t *)argv[1], ZG_MAX_PATH_LENGTH + 1, &options, &handle) == ZG_INVALID_ARGUMENT);
    options.version = ZG_ABI_VERSION + 1;
    assert(zg_open((uint8_t *)argv[1], strlen(argv[1]), &options, &handle) == ZG_INVALID_ARGUMENT);
    assert(handle == NULL);
    options.version = ZG_ABI_VERSION;
    assert(zg_open((uint8_t *)argv[1], strlen(argv[1]), &options, &handle) == ZG_OK);
    assert(zg_write(handle, 1, NULL, 1) == ZG_INVALID_ARGUMENT);
    uint8_t value[1024], output[1024];
    memset(value, 'x', sizeof(value));
    zg_operation operations[2] = {
        {{0, 0, 0, 0, 5}, ZG_PUT, value, sizeof(value)},
        {{0, 1, 0, 0, 5}, ZG_PUT, (uint8_t *)"small", 5}
    };
    assert(zg_write(handle, 1, operations, ZG_MAX_BATCH_RECORDS + 1) == ZG_LIMIT);
    operations[0].value_len = ZG_MAX_VALUE_SIZE + 1;
    assert(zg_write(handle, 1, operations, 1) == ZG_LIMIT);
    operations[0].value_len = sizeof(value);
    assert(zg_write(handle, 1, operations, 2) == ZG_OK);
    size_t required = 0;
    assert(zg_get(handle, &operations[0].key, NULL, 0, &required) == ZG_BUFFER_TOO_SMALL);
    assert(required == sizeof(value));
    assert(zg_get(handle, &operations[0].key, output, sizeof(output), &required) == ZG_OK);
    assert(memcmp(value, output, required) == 0);
    operations[1].key.chunk_x = 32;
    assert(zg_write(handle, 2, operations, 2) == ZG_INVALID_ARGUMENT);
    operations[1].key.chunk_x = 1;
    operations[0].remove = ZG_DELETE;
    operations[0].value = NULL;
    operations[0].value_len = 0;
    assert(zg_write(handle, 2, operations, 2) == ZG_OK);
    assert(zg_compact(handle, 0, 0, 0) == ZG_OK);
    assert(zg_close(handle) == ZG_OK);
    assert(zg_open((uint8_t *)argv[1], strlen(argv[1]), &options, &handle) == ZG_OK);
    assert(zg_get(handle, &operations[0].key, output, sizeof(output), &required) == ZG_NOT_FOUND);
    assert(zg_get(handle, &operations[1].key, output, sizeof(output), &required) == ZG_OK);
    assert(required == 5 && memcmp(output, "small", 5) == 0);
    operations[0].remove = ZG_PUT;
    assert(zg_write(handle, 3, operations, 1) == ZG_OK);
    assert(zg_get(handle, &operations[0].key, NULL, 0, &required) == ZG_OK);
    assert(required == 0);
    zg_batch batches[2] = {{4, operations, 1}, {5, operations + 1, 1}};
    assert(zg_write_group(handle, NULL, 1) == ZG_INVALID_ARGUMENT);
    assert(zg_write_group(handle, batches, ZG_MAX_GROUP_BATCHES + 1) == ZG_LIMIT);
    assert(zg_write_group(handle, batches, 2) == ZG_OK);
    uint64_t last = 0;
    assert(zg_last_batch_id(handle, 0, 0, 0, &last) == ZG_OK && last == 5);
    assert(zg_compact_async(handle, 0, 0, 0) == ZG_OK);
    assert(zg_maintenance_wait(handle) == ZG_OK);
    assert(zg_compact_async(handle, 0, 0, 0) == ZG_OK);
    assert(zg_flush(handle) == ZG_OK);
    assert(zg_close(handle) == ZG_OK);
    assert(zg_close(NULL) == ZG_INVALID_ARGUMENT);
    puts("C API smoke test passed");
    return 0;
}
