#include "harness.h"
#include <leveldb/c.h>
#include <string.h>
#include <sys/resource.h>

enum { CHUNKS = 64, PARTS = 7, GROUP = 16, VALUE_MAX = 16384 };

static uint8_t values[PARTS][VALUE_MAX];
static uint8_t group_values[GROUP][2][VALUE_MAX];
static uint8_t output[PARTS][VALUE_MAX];
static const size_t lengths[PARTS] = {16384, 16384, 16384, 16384, 1536, 256, 1024};
static const uint8_t tags[PARTS] = {0x2f, 0x2f, 0x2f, 0x2f, 0x2b, 0x31, 0x32};

typedef struct {
    zg_handle *zig;
    leveldb_t *leveldb;
    leveldb_readoptions_t *read_options;
    leveldb_writeoptions_t *write_options;
    leveldb_writeoptions_t *sync_options;
    int use_leveldb;
} Store;

static void checkLevelDB(char *error) {
    if (error) {
        fprintf(stderr, "LevelDB: %s\n", error);
        leveldb_free(error);
        exit(1);
    }
}

static void initValues(void) {
    uint32_t random = 42;
    for (int c = 0; c < PARTS; ++c) {
        for (size_t i = 0; i < lengths[c]; ++i) {
            random = random * 1664525u + 1013904223u;
            values[c][i] = (c < 4 && i >= 12288) || c == 6 ? (uint8_t)(random >> 24) : (uint8_t)(i / 64 + c);
        }
    }
}

static int chunkX(size_t slot) {
    return (int)(slot / 16 * 32 + slot % 16);
}

static zg_key zigKey(size_t slot, int part) {
    return (zg_key){0, chunkX(slot), 0, part < 4 ? part - 2 : 0, part < 4 ? ZG_SUBCHUNK : (uint32_t)(part - 3)};
}

static size_t levelKey(size_t slot, int part, uint8_t key[10]) {
    uint32_t x = (uint32_t)chunkX(slot);
    for (int b = 0; b < 4; ++b) key[b] = (uint8_t)(x >> (8 * b));
    memset(key + 4, 0, 4);
    key[8] = tags[part];
    if (part < 4) key[9] = (uint8_t)(part - 2);
    return part < 4 ? 10 : 9;
}

static void openStore(Store *store, const char *path, int use_leveldb, int sync, int group) {
    store->use_leveldb = use_leveldb;
    if (!use_leveldb) {
        zg_options options;
        check(zg_options_init(&options));
        options.buffered = !sync;
        check(zg_open((const uint8_t *)path, strlen(path), &options, &store->zig));
        return;
    }
    leveldb_options_t *options = leveldb_options_create();
    leveldb_options_set_create_if_missing(options, 1);
    leveldb_options_set_compression(options, leveldb_zlib_raw_compression);
    leveldb_options_set_block_size(options, 64 * 1024);
    char *error = NULL;
    store->leveldb = leveldb_open(options, path, &error);
    checkLevelDB(error);
    leveldb_options_destroy(options);
    store->read_options = leveldb_readoptions_create();
    store->write_options = leveldb_writeoptions_create();
    store->sync_options = leveldb_writeoptions_create();
    leveldb_writeoptions_set_sync(store->write_options, sync || group);
    leveldb_writeoptions_set_sync(store->sync_options, 1);
}

static void closeStore(Store *store) {
    if (!store->use_leveldb) {
        check(zg_close(store->zig));
    } else {
        leveldb_close(store->leveldb);
        leveldb_readoptions_destroy(store->read_options);
        leveldb_writeoptions_destroy(store->write_options);
        leveldb_writeoptions_destroy(store->sync_options);
    }
}

static void putLevel(leveldb_writebatch_t *batch, size_t slot, int part, const uint8_t *value) {
    uint8_t key[10];
    size_t key_len = levelKey(slot, part, key);
    leveldb_writebatch_put(batch, (const char *)key, key_len, (const char *)value, lengths[part]);
}

static void flushStore(Store *store) {
    if (!store->use_leveldb) {
        check(zg_flush(store->zig));
    } else {
        leveldb_writebatch_t *marker = leveldb_writebatch_create();
        const char key[] = "benchmark-barrier";
        leveldb_writebatch_put(marker, key, sizeof(key) - 1, "1", 1);
        char *error = NULL;
        leveldb_write(store->leveldb, store->sync_options, marker, &error);
        checkLevelDB(error);
        leveldb_writebatch_destroy(marker);
    }
}

static void writeSaves(Store *store, size_t start, size_t step) {
    zg_operation operations[GROUP][PARTS];
    zg_batch batches[GROUP];
    leveldb_writebatch_t *level_batch = store->use_leveldb ? leveldb_writebatch_create() : NULL;
    for (size_t j = 0; j < step; ++j) {
        size_t i = start + j, slot = i % CHUNKS;
        int full = i < CHUNKS || i % 4 == 0;
        memcpy(group_values[j][0], values[0], lengths[0]);
        memcpy(group_values[j][1], values[6], lengths[6]);
        group_values[j][0][0] = (uint8_t)i;
        group_values[j][1][0] = (uint8_t)i;
        size_t n = 0;
        for (int part = 0; part < PARTS; ++part) {
            if (!full && part != 0 && part != 6) continue;
            const uint8_t *value = part == 0 ? group_values[j][0] : part == 6 ? group_values[j][1] : values[part];
            if (level_batch) putLevel(level_batch, slot, part, value);
            else operations[j][n] = (zg_operation){zigKey(slot, part), ZG_PUT, value, lengths[part]};
            ++n;
        }
        batches[j] = (zg_batch){i + 1, operations[j], n};
    }
    if (level_batch) {
        char *error = NULL;
        leveldb_write(store->leveldb, store->write_options, level_batch, &error);
        checkLevelDB(error);
        leveldb_writebatch_destroy(level_batch);
    } else if (step == 1) {
        check(zg_write(store->zig, batches[0].batch_id, batches[0].operations, batches[0].count));
    } else {
        check(zg_write_group(store->zig, batches, step));
    }
}

static void readPart(Store *store, size_t slot, int part, size_t last) {
    size_t size = 0;
    const uint8_t *data;
    if (!store->use_leveldb) {
        zg_key key = zigKey(slot, part);
        check(zg_get(store->zig, &key, output[part], sizeof(output[part]), &size));
        data = output[part];
    } else {
        uint8_t key[10];
        size_t key_len = levelKey(slot, part, key);
        char *error = NULL;
        data = (const uint8_t *)leveldb_get(store->leveldb, store->read_options, (const char *)key, key_len, &size, &error);
        checkLevelDB(error);
        if (!data) exit(1);
    }
    uint8_t first = part == 0 || part == 6 ? (uint8_t)last : values[part][0];
    if (size != lengths[part] || data[0] != first || memcmp(data + 1, values[part] + 1, size - 1)) exit(1);
    if (store->use_leveldb) leveldb_free((void *)data);
}

static void readChunks(Store *store, size_t count, double *samples, const char *label) {
    uint32_t random = 42;
    double started = now();
    for (size_t i = 0; i < count; ++i) {
        random = random * 1664525u + 1013904223u;
        size_t slot = random % CHUNKS;
        size_t last = slot + CHUNKS * ((count - 1 - slot) / CHUNKS);
        double before = now();
        for (int part = 0; part < PARTS; ++part) readPart(store, slot, part, last);
        samples[i] = now() - before;
    }
    report(label, samples, count, now() - started);
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: pmmp_native EMPTY_DIRECTORY SAVES zig|leveldb buffered|sync|group\n");
        return 1;
    }
    char *end;
    unsigned long parsed = strtoul(argv[2], &end, 10);
    if (*end || parsed < CHUNKS || parsed > 1000000 || parsed % GROUP) return 1;
    size_t count = (size_t)parsed;
    int use_leveldb = strcmp(argv[3], "leveldb") == 0;
    if (!use_leveldb && strcmp(argv[3], "zig")) return 1;
    int group = strcmp(argv[4], "group") == 0;
    int sync = strcmp(argv[4], "sync") == 0;
    if (!group && !sync && strcmp(argv[4], "buffered")) return 1;
    initValues();
    Store store = {0};
    openStore(&store, argv[1], use_leveldb, sync, group);
    double *samples = malloc(count * sizeof(*samples));
    if (!samples) return 1;

    size_t step = group ? GROUP : 1, calls = 0;
    double started = now();
    for (size_t i = 0; i < count; i += step) {
        double before = now();
        writeSaves(&store, i, step);
        if (group && !use_leveldb) flushStore(&store);
        samples[calls++] = now() - before;
    }
    double elapsed = now() - started;
    size_t full_saves = CHUNKS + (count - CHUNKS) / 4;
    size_t raw_bytes = full_saves * (4 * VALUE_MAX + 1536 + 256 + 1024) +
                       (count - full_saves) * (VALUE_MAX + 1024);
    printf("{\"engine\":\"%s\",\"mode\":\"%s\",\"logical_saves\":%zu,"
           "\"full_saves\":%zu,\"partial_saves\":%zu,\"raw_payload_bytes\":%zu,"
           "\"logical_saves_per_second\":%.2f,",
           argv[3], argv[4], count, full_saves, count - full_saves, raw_bytes, count / elapsed);
    report("write_calls", samples, calls, elapsed);
    started = now();
    if (!group && !sync) flushStore(&store);
    printf(",\"final_barrier_ms\":%.3f,", (now() - started) * 1e3);

    readChunks(&store, count, samples, "chunk_reads_first_pass");
    printf(",");
    readChunks(&store, count, samples, "chunk_reads_repeat");

    if (!use_leveldb) {
        zg_read_request requests[PARTS];
        zg_read_result results[PARTS];
        uint32_t random = 42;
        started = now();
        for (size_t i = 0; i < count; ++i) {
            random = random * 1664525u + 1013904223u;
            size_t slot = random % CHUNKS;
            for (int part = 0; part < PARTS; ++part)
                requests[part] = (zg_read_request){zigKey(slot, part), output[part], sizeof(output[part])};
            double before = now();
            check(zg_get_many(store.zig, requests, results, PARTS));
            samples[i] = now() - before;
            size_t last = slot + CHUNKS * ((count - 1 - slot) / CHUNKS);
            for (int part = 0; part < PARTS; ++part) {
                uint8_t first = part == 0 || part == 6 ? (uint8_t)last : values[part][0];
                if (results[part].status != ZG_OK || results[part].required != lengths[part] ||
                    output[part][0] != first || memcmp(output[part] + 1, values[part] + 1, lengths[part] - 1)) exit(1);
            }
        }
        printf(",");
        report("chunk_reads_many", samples, count, now() - started);
        reportStats(store.zig);
    }

    closeStore(&store);
    started = now();
    openStore(&store, argv[1], use_leveldb, sync, group);
    readPart(&store, 0, 0, CHUNKS * ((count - 1) / CHUNKS));
    printf(",\"reopen_and_read_ms\":%.3f", (now() - started) * 1e3);
    closeStore(&store);

    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage)) return 1;
    printf(",\"peak_rss_kib\":%ld,\"cpu_seconds\":%.3f}\n", usage.ru_maxrss,
           usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6);
    free(samples);
    return 0;
}
