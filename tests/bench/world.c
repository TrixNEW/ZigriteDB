// Realistic workloads over a dataset from dataset.c, against ZigriteDB or PMMP's LevelDB.
#define _GNU_SOURCE
#include "harness.h"
#include <fcntl.h>
#include <ftw.h>
#include <leveldb/c.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

enum { MAX_THREADS = 16, RADIUS = 8, MAX_RECORDS = 256 };

typedef struct {
    uint8_t tag;
    int8_t y;
    uint32_t len;
    const uint8_t *value;
} Record;

typedef struct {
    int32_t x, z;
    uint32_t first, count, bytes;
} Chunk;

static Record *records;
static Chunk *chunks;
static size_t chunk_count, record_count, max_chunk_bytes, max_value;
static int32_t min_x, min_z, width, depth;
static int32_t *grid;
static _Atomic uint32_t *versions;
static pthread_mutex_t stripes[256];
static int lock_updates = 1;

static uint64_t cache_bytes;
static int sync_mode, threads = 4, verify = 1;
static size_t ops = 2000;
static double seconds = 10;
static const char *phases = "import,reopen,load,walk,update,autosave,mixed,compact";
static const char *target = "region";
static int read_chunk = 0;
static uint32_t max_regions = 0;

typedef struct {
    int leveldb;
    zg_handle *zig;
    leveldb_t *db;
    leveldb_cache_t *cache;
    leveldb_readoptions_t *read;
    leveldb_writeoptions_t *write, *barrier;
} Store;

static uint32_t component(uint8_t tag) {
#if ZG_ABI_VERSION >= 3
    return tag;
#else
    switch (tag) {
    case 0x2f: return ZG_SUBCHUNK;
    case 0x2b: return ZG_BIOMES;
    case 0x31: return ZG_BLOCK_ENTITIES;
    case 0x32: return ZG_ENTITIES;
    case 0x2c: return ZG_METADATA;
    default: return ZG_HEIGHTMAP;
    }
#endif
}

static zg_key zigKey(const Chunk *chunk, const Record *record) {
    return (zg_key){0, chunk->x, chunk->z, record->tag == 0x2f ? record->y : 0, component(record->tag)};
}

static size_t levelKey(const Chunk *chunk, const Record *record, char key[10]) {
    memcpy(key, &chunk->x, 4);
    memcpy(key + 4, &chunk->z, 4);
    key[8] = (char)record->tag;
    key[9] = (char)record->y;
    return record->tag == 0x2f ? 10 : 9;
}

static void checkLevelDB(char *error) {
    if (!error) return;
    fprintf(stderr, "LevelDB: %s\n", error);
    exit(1);
}

static void loadDataset(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) exit(1);
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    uint8_t *bytes = malloc((size_t)size);
    if (!bytes || fread(bytes, 1, (size_t)size, file) != (size_t)size || memcmp(bytes, "ZGDS", 4)) exit(1);
    fclose(file);
    uint32_t n;
    memcpy(&n, bytes + 4, 4);
    chunk_count = n;
    chunks = calloc(n, sizeof(*chunks));
    size_t capacity = (size_t)n * 40;
    records = malloc(capacity * sizeof(*records));
    uint8_t *p = bytes + 8;
    int32_t max_x = INT32_MIN, max_z = INT32_MIN;
    min_x = min_z = INT32_MAX;
    for (uint32_t c = 0; c < n; c++) {
        Chunk *chunk = &chunks[c];
        uint16_t count;
        memcpy(&chunk->x, p, 4);
        memcpy(&chunk->z, p + 4, 4);
        memcpy(&count, p + 8, 2);
        p += 10;
        chunk->first = (uint32_t)record_count;
        chunk->count = count;
        if (count > MAX_RECORDS) exit(1);
        for (uint16_t i = 0; i < count; i++) {
            if (record_count == capacity) records = realloc(records, (capacity *= 2) * sizeof(*records));
            Record *r = &records[record_count++];
            r->tag = p[0];
            r->y = (int8_t)p[1];
            memcpy(&r->len, p + 2, 4);
            r->value = p + 6;
            p += 6 + r->len;
            chunk->bytes += r->len;
            if (r->len > max_value) max_value = r->len;
        }
        if (chunk->bytes > max_chunk_bytes) max_chunk_bytes = chunk->bytes;
        if (chunk->x < min_x) min_x = chunk->x;
        if (chunk->z < min_z) min_z = chunk->z;
        if (chunk->x > max_x) max_x = chunk->x;
        if (chunk->z > max_z) max_z = chunk->z;
    }
    width = max_x - min_x + 1;
    depth = max_z - min_z + 1;
    grid = malloc((size_t)width * (size_t)depth * sizeof(*grid));
    for (size_t i = 0; i < (size_t)width * (size_t)depth; i++) grid[i] = -1;
    for (uint32_t c = 0; c < n; c++) grid[(size_t)(chunks[c].z - min_z) * (size_t)width + (size_t)(chunks[c].x - min_x)] = (int32_t)c;
    versions = calloc(record_count, sizeof(*versions));
}

static const Chunk *chunkAt(int32_t x, int32_t z) {
    if (x < min_x || z < min_z || x >= min_x + width || z >= min_z + depth) return NULL;
    int32_t c = grid[(size_t)(z - min_z) * (size_t)width + (size_t)(x - min_x)];
    return c < 0 ? NULL : &chunks[c];
}

// Updates flip the first and last byte by the record's version, so readers can check contents.
static void expected(const Record *record, uint32_t version, uint8_t *out) {
    memcpy(out, record->value, record->len);
    if (record->len == 0) return;
    out[0] ^= (uint8_t)version;
    out[record->len - 1] ^= (uint8_t)(version >> 8);
}

static unsigned long long walked_bytes;

static int evictFile(const char *path, const struct stat *info, int type, struct FTW *ftw) {
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

static unsigned long long evict(const char *path) {
    walked_bytes = 0;
    if (nftw(path, evictFile, 16, FTW_PHYS)) exit(1);
    return walked_bytes;
}

typedef struct {
    unsigned long long syscr, syscw, read_bytes, write_bytes;
} IoCounters;

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
    if (!operations) operations = 1;
    printf(",\"%s_io\":{\"read_syscalls_per_op\":%.2f,\"write_syscalls_per_op\":%.2f,"
           "\"disk_read_bytes\":%llu,\"disk_write_bytes\":%llu}",
           name, (double)(after.syscr - before.syscr) / (double)operations,
           (double)(after.syscw - before.syscw) / (double)operations,
           after.read_bytes - before.read_bytes, after.write_bytes - before.write_bytes);
}

static void openStore(Store *store, const char *path, int leveldb) {
    store->leveldb = leveldb;
    if (!leveldb) {
        zg_options options;
        check(zg_options_init(&options));
        options.buffered = !sync_mode;
        options.cache_bytes = cache_bytes;
        if (max_regions) options.max_open_shards = max_regions;
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
    store->db = leveldb_open(options, path, &error);
    checkLevelDB(error);
    leveldb_options_destroy(options);
    store->read = leveldb_readoptions_create();
    leveldb_readoptions_set_verify_checksums(store->read, (uint8_t)verify);
    store->write = leveldb_writeoptions_create();
    store->barrier = leveldb_writeoptions_create();
    leveldb_writeoptions_set_sync(store->write, sync_mode);
    leveldb_writeoptions_set_sync(store->barrier, 1);
}

static void closeStore(Store *store) {
    if (!store->leveldb) {
        check(zg_close(store->zig));
        return;
    }
    leveldb_close(store->db);
    leveldb_cache_destroy(store->cache);
    leveldb_readoptions_destroy(store->read);
    leveldb_writeoptions_destroy(store->write);
    leveldb_writeoptions_destroy(store->barrier);
}

static void flushStore(Store *store) {
    if (!store->leveldb) {
        check(zg_flush(store->zig));
        return;
    }
    leveldb_writebatch_t *batch = leveldb_writebatch_create();
    leveldb_writebatch_put(batch, "benchmark-barrier", 17, "1", 1);
    char *error = NULL;
    leveldb_write(store->db, store->barrier, batch, &error);
    checkLevelDB(error);
    leveldb_writebatch_destroy(batch);
}

static void save(Store *store, const Chunk *chunk, const uint32_t *which, size_t n, uint8_t *const *values) {
    if (!store->leveldb) {
        zg_operation operations[MAX_RECORDS];
        for (size_t i = 0; i < n; i++) {
            const Record *r = &records[chunk->first + which[i]];
            operations[i] = (zg_operation){zigKey(chunk, r), 0, values[i], r->len};
        }
        check(zg_write(store->zig, 0, operations, n));
        return;
    }
    leveldb_writebatch_t *batch = leveldb_writebatch_create();
    for (size_t i = 0; i < n; i++) {
        const Record *r = &records[chunk->first + which[i]];
        char key[10];
        leveldb_writebatch_put(batch, key, levelKey(chunk, r, key), (const char *)values[i], r->len);
    }
    char *error = NULL;
    leveldb_write(store->db, store->write, batch, &error);
    checkLevelDB(error);
    leveldb_writebatch_destroy(batch);
}

static void load(Store *store, const Chunk *chunk, uint8_t *output, int check_values) {
    size_t offset = 0;
#if ZG_ABI_VERSION >= 3
    if (!store->leveldb && read_chunk) {
        zg_chunk_record found[MAX_RECORDS];
        size_t count = 0, required = 0;
        check(zg_get_chunk(store->zig, 0, chunk->x, chunk->z, output, chunk->bytes, found, MAX_RECORDS, &count, &required));
        if (count != chunk->count || required != chunk->bytes) exit(1);
    } else
#endif
    if (!store->leveldb) {
        zg_read_request requests[MAX_RECORDS];
        zg_read_result results[MAX_RECORDS];
        for (uint32_t i = 0; i < chunk->count; i++) {
            const Record *r = &records[chunk->first + i];
            requests[i] = (zg_read_request){zigKey(chunk, r), output + offset, r->len};
            offset += r->len;
        }
        check(zg_get_many(store->zig, requests, results, chunk->count));
        for (uint32_t i = 0; i < chunk->count; i++) {
            if (results[i].status != ZG_OK || results[i].required != records[chunk->first + i].len) {
                fprintf(stderr, "missing record %d,%d #%u status %d\n", chunk->x, chunk->z, i, results[i].status);
                exit(1);
            }
        }
    } else {
        for (uint32_t i = 0; i < chunk->count; i++) {
            const Record *r = &records[chunk->first + i];
            char key[10];
            size_t len = 0;
            char *error = NULL;
            char *value = leveldb_get(store->db, store->read, key, levelKey(chunk, r, key), &len, &error);
            checkLevelDB(error);
            if (!value || len != r->len) exit(1);
            memcpy(output + offset, value, len);
            leveldb_free(value);
            offset += r->len;
        }
    }
    if (!check_values) return;
    static _Thread_local uint8_t *scratch;
    if (!scratch) scratch = malloc(max_value + 1);
    offset = 0;
    for (uint32_t i = 0; i < chunk->count; i++) {
        const Record *r = &records[chunk->first + i];
        expected(r, atomic_load(&versions[chunk->first + i]), scratch);
        if (memcmp(output + offset, scratch, r->len)) {
            fprintf(stderr, "wrong value %d,%d #%u\n", chunk->x, chunk->z, i);
            exit(1);
        }
        offset += r->len;
    }
}

typedef struct {
    Store *store;
    int index;
    uint32_t random;
    double *samples, *extra;
    size_t calls, extra_calls;
    uint8_t *output;
    uint8_t *values[2];
    const Chunk *fixed;
} Worker;

static uint32_t next(uint32_t *random) {
    *random = *random * 1664525u + 1013904223u;
    return *random >> 8;
}

// A partial save: block entities plus one subchunk.
static void update(Worker *worker, const Chunk *chunk) {
    uint32_t which[2];
    size_t n = 0;
    uint32_t subchunks = 0, first_sub = 0;
    which[0] = 0;
    for (uint32_t i = 0; i < chunk->count; i++) {
        uint8_t tag = records[chunk->first + i].tag;
        if (tag == 0x31) which[0] = i;
        if (tag == 0x2f && subchunks++ == 0) first_sub = i;
    }
    n = 1;
    if (subchunks) {
        uint32_t pick = first_sub + next(&worker->random) % subchunks;
        if (pick != which[0]) which[n++] = pick;
    }
    // Ordered per chunk, as a server would, so final contents can be checked.
    pthread_mutex_t *stripe = &stripes[(size_t)(chunk - chunks) % 256];
    if (lock_updates) pthread_mutex_lock(stripe);
    for (size_t i = 0; i < n; i++) {
        uint32_t id = chunk->first + which[i];
        expected(&records[id], atomic_fetch_add(&versions[id], 1) + 1, worker->values[i]);
    }
    save(worker->store, chunk, which, n, worker->values);
    if (lock_updates) pthread_mutex_unlock(stripe);
}

static void saveWhole(Store *store, const Chunk *chunk) {
    uint32_t which[MAX_RECORDS];
    uint8_t *values[MAX_RECORDS];
    for (uint32_t i = 0; i < chunk->count; i++) {
        which[i] = i;
        values[i] = (uint8_t *)records[chunk->first + i].value;
    }
    save(store, chunk, which, chunk->count, values);
}

static Worker workers[MAX_THREADS + 1];

static void initWorkers(size_t samples) {
    for (int t = 0; t <= MAX_THREADS; t++) {
        Worker *w = &workers[t];
        if (!w->output) {
            w->output = malloc(max_chunk_bytes + 1);
            w->values[0] = malloc(max_value + 1);
            w->values[1] = malloc(max_value + 1);
        }
        free(w->samples);
        free(w->extra);
        w->samples = malloc(samples * sizeof(double));
        w->extra = malloc(samples * sizeof(double));
        w->calls = w->extra_calls = 0;
        w->index = t;
        w->random = 42u + (uint32_t)t * 7919u;
    }
}

static void reportSamples(const char *name, int count, int use_extra, double elapsed) {
    size_t total = 0;
    for (int t = 0; t < count; t++) total += use_extra ? workers[t].extra_calls : workers[t].calls;
    double *merged = malloc((total ? total : 1) * sizeof(double));
    size_t at = 0;
    for (int t = 0; t < count; t++) {
        size_t n = use_extra ? workers[t].extra_calls : workers[t].calls;
        memcpy(merged + at, use_extra ? workers[t].extra : workers[t].samples, n * sizeof(double));
        at += n;
    }
    printf(",");
    if (total) report(name, merged, total, elapsed);
    else printf("\"%s\":null", name);
    free(merged);
}

static void runThreads(void *(*fn)(void *), Store *store, int count) {
    pthread_t handles[MAX_THREADS];
    for (int t = 0; t < count; t++) {
        workers[t].store = store;
        if (pthread_create(&handles[t], NULL, fn, &workers[t])) exit(1);
    }
    for (int t = 0; t < count; t++) pthread_join(handles[t], NULL);
}

static void phaseImport(Store *store) {
    initWorkers(chunk_count);
    IoCounters io = ioCounters();
    double started = now();
    for (size_t c = 0; c < chunk_count; c++) {
        double before = now();
        saveWhole(store, &chunks[c]);
        workers[0].samples[workers[0].calls++] = now() - before;
    }
    double written = now();
    flushStore(store);
    double flushed = now();
    reportSamples("import", 1, 0, written - started);
    reportIo("import", io, chunk_count);
    printf(",\"import_flush_ms\":%.3f,\"import_chunks_per_second\":%.1f", (flushed - written) * 1e3,
           chunk_count / (flushed - started));
}

static void phaseLoad(Store *store, const char *name, uint32_t seed) {
    initWorkers(ops);
    uint32_t random = seed;
    IoCounters io = ioCounters();
    double started = now();
    for (size_t i = 0; i < ops; i++) {
        const Chunk *chunk = &chunks[next(&random) % chunk_count];
        double before = now();
        load(store, chunk, workers[0].output, 0);
        workers[0].samples[workers[0].calls++] = now() - before;
    }
    reportSamples(name, 1, 0, now() - started);
    reportIo(name, io, ops);
}

static void verifyAll(Store *store) {
    for (size_t c = 0; c < chunk_count; c++) load(store, &chunks[c], workers[0].output, 1);
}

static void phaseWalk(Store *store) {
    initWorkers((size_t)(width + 1) * (2 * RADIUS + 1) * 2 + (2 * RADIUS + 1) * (2 * RADIUS + 1));
    int32_t z = min_z + depth / 2, x = min_x + RADIUS;
    IoCounters io = ioCounters();
    double started = now();
    for (int32_t dx = -RADIUS; dx <= RADIUS; dx++) {
        for (int32_t dz = -RADIUS; dz <= RADIUS; dz++) {
            const Chunk *chunk = chunkAt(x + dx, z + dz);
            if (!chunk) continue;
            double before = now();
            load(store, chunk, workers[0].output, 0);
            workers[0].extra[workers[0].extra_calls++] = now() - before;
        }
    }
    double spawned = now();
    for (; x + RADIUS + 1 < min_x + width; x++) {
        for (int32_t dz = -RADIUS; dz <= RADIUS; dz++) {
            const Chunk *chunk = chunkAt(x + RADIUS + 1, z + dz);
            if (!chunk) continue;
            double before = now();
            load(store, chunk, workers[0].output, 0);
            workers[0].samples[workers[0].calls++] = now() - before;
        }
    }
    double done = now();
    reportSamples("walk_spawn", 1, 1, spawned - started);
    reportSamples("walk", 1, 0, done - spawned);
    reportIo("walk", io, workers[0].calls + workers[0].extra_calls);
    printf(",\"walk_spawn_ms\":%.3f", (spawned - started) * 1e3);
}

static void phaseUpdate(Store *store, const char *name, size_t count) {
    initWorkers(count);
    workers[0].store = store;
    IoCounters io = ioCounters();
    double started = now();
    for (size_t i = 0; i < count; i++) {
        const Chunk *chunk = &chunks[next(&workers[0].random) % chunk_count];
        double before = now();
        update(&workers[0], chunk);
        workers[0].samples[workers[0].calls++] = now() - before;
    }
    reportSamples(name, 1, 0, now() - started);
    reportIo(name, io, count);
}

static void phaseAutosave(Store *store) {
    enum { ROUNDS = 16, DIRTY = 64 };
    initWorkers(ROUNDS * DIRTY);
    workers[0].store = store;
    IoCounters io = ioCounters();
    double started = now();
    for (int round = 0; round < ROUNDS; round++) {
        for (int i = 0; i < DIRTY; i++) update(&workers[0], &chunks[next(&workers[0].random) % chunk_count]);
        double before = now();
        flushStore(store);
        workers[0].samples[workers[0].calls++] = now() - before;
    }
    reportSamples("autosave_barrier", 1, 0, now() - started);
    reportIo("autosave", io, ROUNDS);
}

static atomic_int stop_mixed;

static void *mixedWorker(void *arg) {
    Worker *w = arg;
    int32_t px = min_x + (int32_t)(next(&w->random) % (uint32_t)width);
    int32_t pz = min_z + (int32_t)(next(&w->random) % (uint32_t)depth);
    for (uint32_t step = 0; !atomic_load(&stop_mixed); step++) {
        if (step % 32 == 31) {
            px += (int32_t)(next(&w->random) % 3) - 1;
            pz += (int32_t)(next(&w->random) % 3) - 1;
            if (px < min_x) px = min_x;
            if (pz < min_z) pz = min_z;
            if (px >= min_x + width) px = min_x + width - 1;
            if (pz >= min_z + depth) pz = min_z + depth - 1;
        }
        int is_update = next(&w->random) % 5 == 0;
        int32_t reach = is_update ? 2 : RADIUS;
        const Chunk *chunk = chunkAt(px + (int32_t)(next(&w->random) % (uint32_t)(2 * reach + 1)) - reach,
                                     pz + (int32_t)(next(&w->random) % (uint32_t)(2 * reach + 1)) - reach);
        if (!chunk) continue;
        double before = now();
        if (is_update) {
            update(w, chunk);
            if (w->extra_calls < ops * 64) w->extra[w->extra_calls++] = now() - before;
        } else {
            load(w->store, chunk, w->output, 0);
            if (w->calls < ops * 64) w->samples[w->calls++] = now() - before;
        }
    }
    return NULL;
}

static void *autosaver(void *arg) {
    Worker *w = arg;
    while (!atomic_load(&stop_mixed)) {
        usleep(250000);
        double before = now();
        flushStore(w->store);
        w->samples[w->calls++] = now() - before;
    }
    return NULL;
}

static void phaseMixed(Store *store) {
    initWorkers(ops * 64);
    atomic_store(&stop_mixed, 0);
    pthread_t saver;
    Worker *saving = &workers[MAX_THREADS];
    saving->store = store;
    if (pthread_create(&saver, NULL, autosaver, saving)) exit(1);
    pthread_t handles[MAX_THREADS];
    for (int t = 0; t < threads; t++) {
        workers[t].store = store;
        if (pthread_create(&handles[t], NULL, mixedWorker, &workers[t])) exit(1);
    }
    double started = now();
    usleep((useconds_t)(seconds * 1e6));
    atomic_store(&stop_mixed, 1);
    for (int t = 0; t < threads; t++) pthread_join(handles[t], NULL);
    pthread_join(saver, NULL);
    double elapsed = now() - started;
    reportSamples("mixed_load", threads, 0, elapsed);
    reportSamples("mixed_update", threads, 1, elapsed);
    double *barriers = malloc((saving->calls ? saving->calls : 1) * sizeof(double));
    memcpy(barriers, saving->samples, saving->calls * sizeof(double));
    printf(",");
    if (saving->calls) report("mixed_barrier", barriers, saving->calls, elapsed);
    else printf("\"mixed_barrier\":null");
    free(barriers);
}

static void compactAll(Store *store) {
    if (store->leveldb) {
        leveldb_compact_range(store->db, NULL, 0, NULL, 0);
        return;
    }
    size_t count = 0;
    int status = zg_list_regions(store->zig, NULL, 0, &count);
    if (status != ZG_OK && status != ZG_BUFFER_TOO_SMALL) check(status);
    zg_region *regions = malloc((count ? count : 1) * sizeof(*regions));
    check(zg_list_regions(store->zig, regions, count, &count));
    for (size_t i = 0; i < count; i++) {
        status = zg_compact(store->zig, regions[i].dimension, regions[i].x, regions[i].z);
        if (status != ZG_OK && status != ZG_NOT_FOUND && status != ZG_CLEANUP_PENDING) check(status);
    }
    free(regions);
}

static int has(const char *phase) {
    size_t len = strlen(phase);
    for (const char *p = phases; (p = strstr(p, phase)); p += len) {
        if ((p == phases || p[-1] == ',') && (p[len] == 0 || p[len] == ',')) return 1;
    }
    return 0;
}

static void *writer(void *arg) {
    Worker *w = arg;
    for (size_t i = 0; i < ops; i++) {
        double before = now();
        update(w, w->fixed);
        w->samples[w->calls++] = now() - before;
    }
    return NULL;
}

static void phaseWriters(Store *store) {
    initWorkers(ops);
    int region_x = chunks[0].x >> 5, region_z = chunks[0].z >> 5;
    const Chunk *same[MAX_THREADS], *spread[MAX_THREADS];
    int same_count = 0, spread_count = 0;
    int seen_x[MAX_THREADS], seen_z[MAX_THREADS];
    for (size_t c = 0; c < chunk_count; c++) {
        const Chunk *chunk = &chunks[c];
        if (same_count < MAX_THREADS && chunk->x >> 5 == region_x && chunk->z >> 5 == region_z) same[same_count++] = chunk;
        int fresh = spread_count < MAX_THREADS;
        for (int i = 0; fresh && i < spread_count; i++) {
            if (seen_x[i] == chunk->x >> 5 && seen_z[i] == chunk->z >> 5) fresh = 0;
        }
        if (fresh) {
            seen_x[spread_count] = chunk->x >> 5;
            seen_z[spread_count] = chunk->z >> 5;
            spread[spread_count++] = chunk;
        }
    }
    for (int t = 0; t < threads; t++) {
        if (!strcmp(target, "chunk")) workers[t].fixed = &chunks[0];
        else if (!strcmp(target, "region")) workers[t].fixed = same[t % same_count];
        else workers[t].fixed = spread[t % spread_count];
    }
    IoCounters io = ioCounters();
    double started = now();
    runThreads(writer, store, threads);
    double elapsed = now() - started;
    reportSamples("writers", threads, 0, elapsed);
    reportIo("writers", io, ops * (size_t)threads);
    printf(",\"writer_saves_per_second\":%.1f,\"distinct_regions\":%d", ops * threads / elapsed,
           !strcmp(target, "regions") ? (spread_count < threads ? spread_count : threads) : 1);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: world_bench EMPTY_DIR zig|leveldb DATASET [cache=MiB] [threads=N] [ops=N] [seconds=S]\n"
                        "       [mode=buffered|sync] [phases=a,b] [target=chunk|region|regions] [verify=0|1] [regions=N]\n");
        return 1;
    }
    const char *path = argv[1];
    int leveldb = !strcmp(argv[2], "leveldb");
    if (!leveldb && strcmp(argv[2], "zig")) return 1;
    for (int i = 4; i < argc; i++) {
        char *value = strchr(argv[i], '=');
        if (!value) return 1;
        *value++ = 0;
        if (!strcmp(argv[i], "cache")) cache_bytes = strtoull(value, NULL, 10) << 20;
        else if (!strcmp(argv[i], "threads")) threads = atoi(value);
        else if (!strcmp(argv[i], "ops")) ops = strtoul(value, NULL, 10);
        else if (!strcmp(argv[i], "seconds")) seconds = atof(value);
        else if (!strcmp(argv[i], "mode")) sync_mode = !strcmp(value, "sync");
        else if (!strcmp(argv[i], "phases")) phases = value;
        else if (!strcmp(argv[i], "target")) target = value;
        else if (!strcmp(argv[i], "verify")) verify = atoi(value);
        else if (!strcmp(argv[i], "read")) read_chunk = !strcmp(value, "chunk");
        else if (!strcmp(argv[i], "regions")) max_regions = (uint32_t)strtoul(value, NULL, 10);
        else return 1;
    }
    if (threads < 1 || threads > MAX_THREADS || !ops) return 1;
    for (int i = 0; i < 256; i++) pthread_mutex_init(&stripes[i], NULL);
    loadDataset(argv[3]);
    size_t raw = 0;
    for (size_t c = 0; c < chunk_count; c++) raw += chunks[c].bytes;
    printf("{\"engine\":\"%s\",\"mode\":\"%s\",\"chunks\":%zu,\"records\":%zu,\"raw_bytes\":%zu,\"cache_mib\":%llu,"
           "\"threads\":%d,\"ops\":%zu,\"phases\":\"%s\",\"target\":\"%s\"",
           argv[2], sync_mode ? "sync" : "buffered", chunk_count, record_count, raw,
           (unsigned long long)(cache_bytes >> 20), threads, ops, phases, target);

    Store store = {0};
    openStore(&store, path, leveldb);
    if (has("writers")) {
        for (size_t c = 0; c < chunk_count; c++) saveWhole(&store, &chunks[c]);
        flushStore(&store);
        lock_updates = 0;
        phaseWriters(&store);
        if (!leveldb) reportStatsAs("stats", store.zig);
        closeStore(&store);
        printf("}\n");
        return 0;
    }
    phaseImport(&store);
    if (!leveldb) reportStatsAs("import_stats", store.zig);
    closeStore(&store);
    printf(",\"database_bytes\":%llu", evict(path));

    double started = now();
    openStore(&store, path, leveldb);
    load(&store, &chunks[chunk_count / 2], workers[0].output, 1);
    printf(",\"reopen_and_first_load_ms\":%.3f", (now() - started) * 1e3);
    if (has("load")) {
        evict(path);
        phaseLoad(&store, "load_cold", 7);
        phaseLoad(&store, "load_hot", 7);
    }
    if (has("walk")) {
        closeStore(&store);
        evict(path);
        openStore(&store, path, leveldb);
        phaseWalk(&store);
    }
    if (has("update")) {
        phaseUpdate(&store, "update", ops);
        flushStore(&store);
    }
    if (has("autosave")) phaseAutosave(&store);
    if (has("mixed")) phaseMixed(&store);
    if (!leveldb) reportStatsAs("stats", store.zig);
    closeStore(&store);
    printf(",\"updated_database_bytes\":%llu", evict(path));

    started = now();
    openStore(&store, path, leveldb);
    load(&store, &chunks[0], workers[0].output, 1);
    printf(",\"reopen_after_updates_ms\":%.3f", (now() - started) * 1e3);
    if (has("compact")) {
        started = now();
        compactAll(&store);
        printf(",\"compaction_ms\":%.3f", (now() - started) * 1e3);
    }
    initWorkers(1);
    verifyAll(&store);
    closeStore(&store);
    printf(",\"final_database_bytes\":%llu", evict(path));

    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage)) return 1;
    printf(",\"peak_rss_kib\":%ld,\"cpu_seconds\":%.3f}\n", usage.ru_maxrss,
           usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6);
    return 0;
}
