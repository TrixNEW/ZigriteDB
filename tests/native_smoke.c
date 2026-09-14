#include "zigritedb.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    zg_options options;
    assert(zg_options_init(&options) == ZG_OK);
    assert(options.version == 1 && options.struct_size == sizeof(options));
    options.batch_buffer_size = 4096;
    options.max_segment_size = 4096;
    zg_handle *handle = NULL;
    options.version = 2;
    assert(zg_open((uint8_t *)argv[1], strlen(argv[1]), &options, &handle) == ZG_INVALID_ARGUMENT);
    assert(handle == NULL);
    options.version = 1;
    assert(zg_open((uint8_t *)argv[1], strlen(argv[1]), &options, &handle) == ZG_OK);
    assert(zg_write(handle, 1, NULL, 1) == ZG_INVALID_ARGUMENT);
    uint8_t value[1024], output[1024];
    memset(value, 'x', sizeof(value));
    zg_operation operations[2] = {
        {{0, 0, 0, 0, 5}, 0, value, sizeof(value)},
        {{0, 1, 0, 0, 5}, 0, (uint8_t *)"small", 5}
    };
    assert(zg_write(handle, 1, operations, 2) == ZG_OK);
    size_t required = 0;
    assert(zg_get(handle, &operations[0].key, NULL, 0, &required) == ZG_BUFFER_TOO_SMALL);
    assert(required == sizeof(value));
    assert(zg_get(handle, &operations[0].key, output, sizeof(output), &required) == ZG_OK);
    assert(memcmp(value, output, required) == 0);
    operations[1].key.chunk_x = 32;
    assert(zg_write(handle, 2, operations, 2) == ZG_INVALID_ARGUMENT);
    operations[1].key.chunk_x = 1;
    operations[0].remove = 1;
    operations[0].value = NULL;
    operations[0].value_len = 0;
    assert(zg_write(handle, 2, operations, 2) == ZG_OK);
    assert(zg_compact(handle, 0, 0, 0) == ZG_OK);
    assert(zg_close(handle) == ZG_OK);
    assert(zg_open((uint8_t *)argv[1], strlen(argv[1]), &options, &handle) == ZG_OK);
    assert(zg_get(handle, &operations[0].key, output, sizeof(output), &required) == ZG_NOT_FOUND);
    assert(zg_get(handle, &operations[1].key, output, sizeof(output), &required) == ZG_OK);
    assert(required == 5 && memcmp(output, "small", 5) == 0);
    operations[0].remove = 0;
    assert(zg_write(handle, 3, operations, 1) == ZG_OK);
    assert(zg_get(handle, &operations[0].key, NULL, 0, &required) == ZG_OK);
    assert(required == 0);
    assert(zg_flush(handle) == ZG_OK);
    assert(zg_close(handle) == ZG_OK);
    assert(zg_close(NULL) == ZG_INVALID_ARGUMENT);
    puts("C API smoke test passed");
    return 0;
}
