#define _XOPEN_SOURCE 700
#include "harness.h"
#include <fcntl.h>
#include <ftw.h>
#include <leveldb/c.h>
#include <pthread.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

enum { PARTS = 7, GROUP = 16, VALUE_MAX = 16384, MAX_THREADS = 32, WIDTH = 64 };

static uint8_t values[PARTS][VALUE_MAX];
static const size_t lengths[PARTS] = {16384, 16384, 16384, 16384, 1536, 256, 1024};
static const uint8_t tags[PARTS] = {0x2f, 0x2f, 0x2f, 0x2f, 0x2b, 0x31, 0x32};
static size_t chunks = 64, saves = 1024;
static int threads = 1, verify = 1;
static uint64_t cache_bytes = 0;

typedef struct {
    zg_handle *zig;
    leveldb_t *leveldb;
    leveldb_cache_t *cache;
    leveldb_readoptions_t *read_options;
    leveldb_writeoptions_t *write_options;
    leveldb_writeoptions_t *sync_options;
    int use_leveldb;
} Store;

typedef struct {
    Store *store;
    int index, step;
    double *samples;
    size_t calls;
    uint8_t buffers[GROUP][2][VALUE_MAX];
    uint8_t output[PARTS][VALUE_MAX];
} Worker;

typedef struct {
    unsigned long long syscr, syscw, read_bytes, write_bytes;
} IoCounters;

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

static int chunkX(size_t slot) { return (int)(slot % WIDTH); }
static int chunkZ(size_t slot) { return (int)(slot / WIDTH); }

static zg_key zigKey(size_t slot, int part) {
    return (zg_key){0, chunkX(slot), chunkZ(slot), part < 4 ? part - 2 : 0, part < 4 ? ZG_SUBCHUNK : (uint32_t)(part - 3)};
}

static size_t levelKey(size_t slot, int part, uint8_t key[10]) {
    uint32_t x = (uint32_t)chunkX(slot), z = (uint32_t)chunkZ(slot);
    for (int b = 0; b < 4; ++b) {
        key[b] = (uint8_t)(x >> (8 * b));
        key[4 + b] = (uint8_t)(z >> (8 * b));
    }
    key[8] = tags[part];
    if (part < 4) key[9] = (uint8_t)(part - 2);
    return part < 4 ? 10 : 9;
}

static size_t lastSave(size_t slot) {
    return slot + chunks * ((saves - 1 - slot) / chunks);
}

static IoCounters ioCounters(void) {
    IoCounters counters = {0};
    FILE *file = fopen("/proc/self/io", "r");
    if (!file) return counters;
    char name[32];
    unsigned long long value;
    while (fscanf(file, "%31[^:]: %llu\n", name, &value) == 2) {
        if (!strcmp(name, "syscr")) counters.syscr = value;
        else if (!strcmp(name, "syscw")) counters.syscw = value;
        else if (!strcmp(name, "read_bytes")) counters.read_bytes = value;
        else if (!strcmp(name, "write_bytes")) counters.write_bytes = value;
    }
    fclose(file);
    return counters;
}

static void reportIo(const char *name, IoCounters before, size_t operations) {
    IoCounters after = ioCounters();
    printf(",\"%s_io\":{\"read_syscalls_per_op\":%.2f,\"write_syscalls_per_op\":%.2f,"
           "\"disk_read_bytes\":%llu,\"disk_write_bytes\":%llu}",
           name, (double)(after.syscr - before.syscr) / (double)operations,
           (double)(after.syscw - before.syscw) / (double)operations,
           after.read_bytes - before.read_bytes, after.write_bytes - before.write_bytes);
}

static unsigned long long walked_bytes;

static int addFile(const char *path, const struct stat *info, int type, struct FTW *ftw) {
    (void)ftw;
    if (type != FTW_F) return 0;
    walked_bytes += (unsigned long long)info->st_size;
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
        close(fd);
    }
    return 0;
}

static unsigned long long walkAndEvict(const char *path) {
    walked_bytes = 0;
    if (nftw(path, addFile, 16, FTW_PHYS)) exit(1);
    return walked_bytes;
}

static void openStore(Store *store, const char *path, int use_leveldb, int sync, int group) {
    store->use_leveldb = use_leveldb;
    if (!use_leveldb) {
        zg_options options;
        check(zg_options_init(&options));
        options.buffered = !sync;
        options.cache_bytes = cache_bytes;
        check(zg_open((const uint8_t *)path, strlen(path), &options, &store->zig));
        return;
    }
    leveldb_options_t *options = leveldb_options_create();
    leveldb_options_set_create_if_missing(options, 1);
    leveldb_options_set_compression(options, leveldb_zlib_raw_compression);
    leveldb_options_set_block_size(options, 64 * 1024);
    store->cache = leveldb_cache_create_lru(cache_bytes);
    leveldb_options_set_cache(options, store->cache);
    char *error = NULL;
    store->leveldb = leveldb_open(options, path, &error);
    checkLevelDB(error);
    leveldb_options_destroy(options);
    store->read_options = leveldb_readoptions_create();
    leveldb_readoptions_set_verify_checksums(store->read_options, (uint8_t)verify);
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
        leveldb_cache_destroy(store->cache);
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

static void writeSaves(Store *store, Worker *worker, size_t start, size_t step, int assign_ids) {
    zg_operation operations[GROUP][PARTS];
    zg_batch batches[GROUP];
    leveldb_writebatch_t *level_batch = store->use_leveldb ? leveldb_writebatch_create() : NULL;
    for (size_t j = 0; j < step; ++j) {
        size_t i = start + j, slot = i % chunks;
        int full = i < chunks || i % 4 == 0;
        memcpy(worker->buffers[j][0], values[0], lengths[0]);
        memcpy(worker->buffers[j][1], values[6], lengths[6]);
        worker->buffers[j][0][0] = (uint8_t)i;
        worker->buffers[j][1][0] = (uint8_t)i;
        size_t n = 0;
        for (int part = 0; part < PARTS; ++part) {
            if (!full && part != 0 && part != 6) continue;
            const uint8_t *value = part == 0 ? worker->buffers[j][0] : part == 6 ? worker->buffers[j][1] : values[part];
            if (level_batch) putLevel(level_batch, slot, part, value);
            else operations[j][n] = (zg_operation){zigKey(slot, part), ZG_PUT, value, lengths[part]};
            ++n;
        }
        batches[j] = (zg_batch){assign_ids ? 0 : i + 1, operations[j], n};
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

static void readPart(Store *store, uint8_t output[VALUE_MAX], size_t slot, int part) {
    size_t size = 0;
    const uint8_t *data;
    if (!store->use_leveldb) {
        zg_key key = zigKey(slot, part);
        check(zg_get(store->zig, &key, output, VALUE_MAX, &size));
        data = output;
    } else {
        uint8_t key[10];
        size_t key_len = levelKey(slot, part, key);
        char *error = NULL;
        data = (const uint8_t *)leveldb_get(store->leveldb, store->read_options, (const char *)key, key_len, &size, &error);
        checkLevelDB(error);
        if (!data) exit(1);
    }
    uint8_t first = part == 0 || part == 6 ? (uint8_t)lastSave(slot) : values[part][0];
    if (size != lengths[part] || data[0] != first || memcmp(data + 1, values[part] + 1, size - 1)) exit(1);
    if (store->use_leveldb) leveldb_free((void *)data);
}

static void *writeWorker(void *arg) {
    Worker *worker = arg;
    for (size_t i = 0; i < saves; ++i) {
        if ((int)((i % chunks) % (size_t)threads) != worker->index) continue;
        double before = now();
        writeSaves(worker->store, worker, i, 1, threads > 1);
        worker->samples[worker->calls++] = now() - before;
    }
    return NULL;
}

static void *groupWorker(void *arg) {
    Worker *worker = arg;
    for (size_t i = 0; i < saves; i += GROUP) {
        double before = now();
        writeSaves(worker->store, worker, i, GROUP, 0);
        if (!worker->store->use_leveldb) flushStore(worker->store);
        worker->samples[worker->calls++] = now() - before;
    }
    return NULL;
}

static void *readWorker(void *arg) {
    Worker *worker = arg;
    uint32_t random = 42 + (uint32_t)worker->index;
    size_t count = saves / (size_t)threads;
    for (size_t i = 0; i < count; ++i) {
        random = random * 1664525u + 1013904223u;
        size_t slot = random % chunks;
        double before = now();
        for (int part = 0; part < PARTS; ++part) readPart(worker->store, worker->output[part], slot, part);
        worker->samples[worker->calls++] = now() - before;
    }
    return NULL;
}

static void *manyWorker(void *arg) {
    Worker *worker = arg;
    zg_read_request requests[PARTS];
    zg_read_result results[PARTS];
    uint32_t random = 42 + (uint32_t)worker->index;
    size_t count = saves / (size_t)threads;
    for (size_t i = 0; i < count; ++i) {
        random = random * 1664525u + 1013904223u;
        size_t slot = random % chunks;
        for (int part = 0; part < PARTS; ++part)
            requests[part] = (zg_read_request){zigKey(slot, part), worker->output[part], VALUE_MAX};
        double before = now();
        check(zg_get_many(worker->store->zig, requests, results, PARTS));
        worker->samples[worker->calls++] = now() - before;
        for (int part = 0; part < PARTS; ++part) {
            uint8_t first = part == 0 || part == 6 ? (uint8_t)lastSave(slot) : values[part][0];
            if (results[part].status != ZG_OK || results[part].required != lengths[part] ||
                worker->output[part][0] != first || memcmp(worker->output[part] + 1, values[part] + 1, lengths[part] - 1)) exit(1);
        }
    }
    return NULL;
}

static Worker *workers;

static void runPhase(const char *label, void *(*fn)(void *), Store *store, int count) {
    pthread_t handles[MAX_THREADS];
    IoCounters io = ioCounters();
    double started = now();
    for (int t = 0; t < count; ++t) {
        workers[t].store = store;
        workers[t].index = t;
        workers[t].calls = 0;
        if (pthread_create(&handles[t], NULL, fn, &workers[t])) exit(1);
    }
    for (int t = 0; t < count; ++t) pthread_join(handles[t], NULL);
    double elapsed = now() - started;
    double *merged = malloc(saves * sizeof(*merged));
    size_t total = 0;
    if (!merged) exit(1);
    for (int t = 0; t < count; ++t) {
        memcpy(merged + total, workers[t].samples, workers[t].calls * sizeof(*merged));
        total += workers[t].calls;
    }
    printf(",");
    report(label, merged, total, elapsed);
    reportIo(label, io, total);
    free(merged);
}

static void compactStore(Store *store) {
    if (store->use_leveldb) {
        leveldb_compact_range(store->leveldb, NULL, 0, NULL, 0);
        return;
    }
    for (size_t slot = 0; slot < chunks; slot += 32 * WIDTH) {
        for (int x = 0; x < WIDTH; x += 32) {
            int status = zg_compact(store->zig, 0, x / 32, chunkZ(slot) / 32);
            if (status != ZG_OK && status != ZG_NOT_FOUND) check(status);
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 5 || argc > 9) {
        fprintf(stderr, "usage: pmmp_native EMPTY_DIRECTORY SAVES zig|leveldb buffered|sync|group [CHUNKS] [CACHE_MIB] [VERIFY] [THREADS]\n");
        return 1;
    }
    saves = strtoul(argv[2], NULL, 10);
    if (argc > 5) chunks = strtoul(argv[5], NULL, 10);
    if (argc > 6) cache_bytes = strtoull(argv[6], NULL, 10) << 20;
    if (argc > 7) verify = atoi(argv[7]) != 0;
    if (argc > 8) threads = atoi(argv[8]);
    int use_leveldb = strcmp(argv[3], "leveldb") == 0;
    int group = strcmp(argv[4], "group") == 0;
    int sync = strcmp(argv[4], "sync") == 0;
    int invalid = chunks < 16 || chunks > 1000000 || saves < chunks || saves > 1000000 || saves % GROUP ||
                  threads < 1 || threads > MAX_THREADS || (size_t)threads > chunks || (group && threads != 1) ||
                  (!use_leveldb && strcmp(argv[3], "zig")) || (!group && !sync && strcmp(argv[4], "buffered"));
    if (invalid) {
        fprintf(stderr, "invalid arguments\n");
        return 1;
    }
    initValues();
    workers = calloc((size_t)threads, sizeof(*workers));
    if (!workers) return 1;
    for (int t = 0; t < threads; ++t) {
        workers[t].samples = malloc(saves * sizeof(double));
        if (!workers[t].samples) return 1;
    }

    Store store = {0};
    openStore(&store, argv[1], use_leveldb, sync, group);
    size_t full_saves = chunks + (saves - chunks + 3) / 4;
    size_t raw_bytes = full_saves * (4 * VALUE_MAX + 1536 + 256 + 1024) + (saves - full_saves) * (VALUE_MAX + 1024);
    printf("{\"engine\":\"%s\",\"mode\":\"%s\",\"logical_saves\":%zu,\"chunks\":%zu,\"cache_mib\":%llu,"
           "\"verify_checksums\":%d,\"threads\":%d,\"raw_payload_bytes\":%zu",
           argv[3], argv[4], saves, chunks, (unsigned long long)(cache_bytes >> 20), verify, threads, raw_bytes);

    double started = now();
    runPhase("write_calls", group ? groupWorker : writeWorker, &store, group ? 1 : threads);
    printf(",\"logical_saves_per_second\":%.2f", saves / (now() - started));
    started = now();
    if (!group && !sync) flushStore(&store);
    printf(",\"final_barrier_ms\":%.3f", (now() - started) * 1e3);
    closeStore(&store);

    printf(",\"database_bytes\":%llu", walkAndEvict(argv[1]));
    started = now();
    openStore(&store, argv[1], use_leveldb, sync, group);
    readPart(&store, workers[0].output[0], 0, 0);
    printf(",\"cold_reopen_and_read_ms\":%.3f", (now() - started) * 1e3);
    walkAndEvict(argv[1]);

    runPhase("chunk_reads_cold", readWorker, &store, threads);
    runPhase("chunk_reads_hot", readWorker, &store, threads);
    if (!use_leveldb) {
        runPhase("chunk_reads_many", manyWorker, &store, threads);
        reportStats(store.zig);
    }

    started = now();
    compactStore(&store);
    printf(",\"compaction_ms\":%.3f", (now() - started) * 1e3);
    closeStore(&store);
    printf(",\"compacted_database_bytes\":%llu", walkAndEvict(argv[1]));

    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage)) return 1;
    printf(",\"peak_rss_kib\":%ld,\"cpu_seconds\":%.3f}\n", usage.ru_maxrss,
           usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6);
    for (int t = 0; t < threads; ++t) free(workers[t].samples);
    free(workers);
    return 0;
}
