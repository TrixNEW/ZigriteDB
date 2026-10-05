#define _POSIX_C_SOURCE 200809L
#include "zigritedb.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum { REGIONS = 8, SLOTS = 4, CHUNKS = REGIONS * SLOTS, WRITERS = 4, READERS = 3, VALUE_MAX = 512, AUX_KEYS = 4 };
static zg_handle *handle;
static pthread_mutex_t locks[CHUNKS], aux_locks[AUX_KEYS];
static uint64_t versions[CHUNKS], aux_versions[AUX_KEYS];
static atomic_bool stopped;
static size_t operations = 400;

static void check(int status) {
    if (status != ZG_OK) {
        fprintf(stderr, "C API: %s (%d)\n", zg_status_message(status), status);
        abort();
    }
}

static double now(void) {
    struct timespec time;
    assert(clock_gettime(CLOCK_MONOTONIC, &time) == 0);
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static uint32_t next(uint32_t *seed) {
    *seed = *seed * 1664525u + 1013904223u;
    return *seed;
}

static zg_key key(size_t id, int component) {
    return (zg_key){0, (int32_t)(id / SLOTS) * 32 + (int32_t)(id % SLOTS), 0,
                    component ? -1 : 0, component ? ZG_SUBCHUNK : ZG_VERSION};
}

static int present(uint64_t version, int component) {
    return version != 0 && (version + (unsigned)component) % 11 != 0;
}

static size_t value(size_t id, int component, uint64_t version, uint8_t *out) {
    size_t length = version % 7 == 0 ? 0 : 64 + ((version + id + (unsigned)component) % 4) * 128;
    for (size_t i = 0; i < length; i++)
        out[i] = (uint8_t)((version >> ((i % 8) * 8)) ^ (id * 31 + (unsigned)component * 17) ^ (i % 32));
    return length;
}

static void validate(int status, size_t required, const uint8_t *output, size_t id, int component, uint64_t version) {
    if (!present(version, component)) {
        assert(status == ZG_NOT_FOUND && required == 0);
        return;
    }
    uint8_t expected[VALUE_MAX];
    size_t length = value(id, component, version, expected);
    assert(status == ZG_OK && required == length && memcmp(output, expected, length) == 0);
}

// A chunk's model lock orders its writes; other chunks in the region still contend in the engine.
static void writeChunk(size_t id, int grouped) {
    assert(pthread_mutex_lock(&locks[id]) == 0);
    uint8_t bytes[4][VALUE_MAX];
    zg_operation puts[4];
    zg_batch batches[2];
    size_t count = grouped ? 2 : 1;
    for (size_t batch = 0; batch < count; batch++) {
        uint64_t version = versions[id] + batch + 1;
        for (int component = 0; component < 2; component++) {
            size_t i = batch * 2 + (size_t)component;
            size_t length = value(id, component, version, bytes[i]);
            puts[i] = (zg_operation){key(id, component), present(version, component) ? ZG_PUT : ZG_DELETE,
                                     bytes[i], length};
            if (puts[i].remove == ZG_DELETE) puts[i].value_len = 0;
        }
        batches[batch] = (zg_batch){0, puts + batch * 2, 2};
    }
    if (grouped) check(zg_write_group(handle, batches, count));
    else check(zg_write(handle, 0, puts, 2));
    versions[id] += count;
    assert(pthread_mutex_unlock(&locks[id]) == 0);
}

static void readChunk(size_t id, unsigned mode) {
    assert(pthread_mutex_lock(&locks[id]) == 0);
    uint64_t version = versions[id];
    uint8_t output[2][VALUE_MAX];
    size_t required = 0;
    if (mode == 0) {
        for (int component = 0; component < 2; component++) {
            zg_key k = key(id, component);
            int status = zg_get(handle, &k, output[component], VALUE_MAX, &required);
            validate(status, required, output[component], id, component, version);
        }
    } else if (mode == 1) {
        zg_read_request requests[2] = {{key(id, 0), output[0], VALUE_MAX}, {key(id, 1), output[1], VALUE_MAX}};
        zg_read_result results[2];
        check(zg_get_many(handle, requests, results, 2));
        for (int component = 0; component < 2; component++)
            validate(results[component].status, results[component].required, output[component], id, component, version);
    } else {
        uint8_t bytes[VALUE_MAX * 2];
        zg_chunk_record records[2];
        size_t count = 0, expected_count = 0, expected_bytes = 0;
        for (int component = 0; component < 2; component++) if (present(version, component)) {
            expected_count++;
            expected_bytes += value(id, component, version, output[component]);
        }
        zg_key k = key(id, 0);
        int status = zg_get_chunk(handle, 0, k.chunk_x, 0, bytes, sizeof(bytes), records, 2, &count, &required);
        assert(status == (expected_count ? ZG_OK : ZG_NOT_FOUND));
        assert(count == expected_count && required == expected_bytes);
        size_t i = 0;
        for (int component = 0; component < 2; component++) if (present(version, component)) {
            assert(records[i].component == key(id, component).component);
            assert(records[i].subchunk_y == key(id, component).subchunk_y);
            assert(records[i].offset <= required && records[i].length <= required - records[i].offset);
            validate(ZG_OK, records[i].length, bytes + records[i].offset, id, component, version);
            i++;
        }
    }
    assert(pthread_mutex_unlock(&locks[id]) == 0);
}

static void auxiliary(size_t id, int write) {
    assert(pthread_mutex_lock(&aux_locks[id]) == 0);
    char name[64];
    int length = snprintf(name, sizeof(name), "~zigritedb_soak_player_%zu", id);
    assert(length > 0 && (size_t)length < sizeof(name));
    uint8_t bytes[VALUE_MAX];
    uint64_t version = aux_versions[id] + (write != 0);
    size_t size = value(id, 0, version, bytes);
    if (write) {
        if (present(version, 0)) check(zg_aux_put(handle, (const uint8_t *)name, (size_t)length, bytes, size));
        else check(zg_aux_delete(handle, (const uint8_t *)name, (size_t)length));
        aux_versions[id] = version;
    }
    size_t required = 0;
    int status = zg_aux_get(handle, (const uint8_t *)name, (size_t)length, bytes, sizeof(bytes), &required);
    validate(status, required, bytes, id, 0, aux_versions[id]);
    assert(pthread_mutex_unlock(&aux_locks[id]) == 0);
}

typedef struct { uint32_t seed; } Worker;

static void *writer(void *arg) {
    Worker *worker = arg;
    for (size_t i = 0; i < operations; i++) {
        uint32_t pick = next(&worker->seed);
        size_t region = pick % 2 ? 0 : (pick >> 8) % REGIONS;
        size_t id = region * SLOTS + (next(&worker->seed) >> 8) % SLOTS;
        writeChunk(id, next(&worker->seed) % 8 == 0);
        if (i % 8 == 0) auxiliary((next(&worker->seed) >> 8) % AUX_KEYS, 1);
    }
    return NULL;
}

static void *reader(void *arg) {
    Worker *worker = arg;
    do {
        size_t id = (next(&worker->seed) >> 8) % CHUNKS;
        readChunk(id, (next(&worker->seed) >> 8) % 3);
        auxiliary((next(&worker->seed) >> 8) % AUX_KEYS, 0);
    } while (!atomic_load(&stopped));
    return NULL;
}

static void *maintenance(void *arg) {
    Worker *worker = arg;
    do {
        check(zg_flush(handle));
        zg_key keys[CHUNKS];
        for (size_t id = 0; id < CHUNKS; id++) keys[id] = key(id, 1);
        check(zg_prefetch(handle, keys, CHUNKS));
        int32_t region = (int32_t)((next(&worker->seed) >> 8) % REGIONS);
        int status = zg_compact_async(handle, 0, region, 0);
        assert(status == ZG_OK || status == ZG_BUSY);
        status = zg_maintenance_wait(handle);
        assert(status == ZG_OK || status == ZG_NOT_FOUND);
        status = zg_compact(handle, 0, (region + 1) % REGIONS, 0);
        assert(status == ZG_OK || status == ZG_NOT_FOUND);
        struct timespec delay = {0, 10000000};
        assert(nanosleep(&delay, NULL) == 0);
    } while (!atomic_load(&stopped));
    return NULL;
}

static size_t entries(const char *path) {
    DIR *dir = opendir(path);
    assert(dir != NULL);
    size_t count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) count++;
    assert(closedir(dir) == 0);
    return count;
}

static void resources(size_t fd_count, size_t thread_count) {
    assert(entries("/proc/self/fd") == fd_count);
    // Joined threads can remain in /proc briefly while the kernel finishes exit.
    double deadline = now() + 1;
    while (entries("/proc/self/task") != thread_count && now() < deadline) {
        struct timespec delay = {0, 1000000};
        assert(nanosleep(&delay, NULL) == 0);
    }
    assert(entries("/proc/self/task") == thread_count);
}

static void path(char out[ZG_MAX_PATH_LENGTH], const char *root, const char *name) {
    int length = snprintf(out, ZG_MAX_PATH_LENGTH, "%s/%s", root, name);
    assert(length > 0 && length < (int)ZG_MAX_PATH_LENGTH);
}

static void verify(void) {
    for (size_t id = 0; id < CHUNKS; id++) for (unsigned mode = 0; mode < 3; mode++) readChunk(id, mode);
    for (size_t id = 0; id < AUX_KEYS; id++) auxiliary(id, 0);
}

static void failures(const char *root, zg_options options) {
    char source[ZG_MAX_PATH_LENGTH], segment[ZG_MAX_PATH_LENGTH], region[ZG_MAX_PATH_LENGTH], target[ZG_MAX_PATH_LENGTH];
    path(source, root, "write-error");
    assert(mkdir(source, 0700) == 0);
    options.compact_live_percent = 0;
    check(zg_open((const uint8_t *)source, strlen(source), &options, &handle));
    zg_operation put = {{0, 0, 0, 0, ZG_VERSION}, ZG_PUT, (const uint8_t *)"durable", 7};
    check(zg_write(handle, 1, &put, 1));
    check(zg_flush(handle));
    path(region, source, "00000000-00000000-00000000.region");
    path(segment, region, "0000000000000001-0000000000000001.segment");
    struct stat info;
    assert(stat(segment, &info) == 0);
    struct rlimit saved, limit;
    assert(getrlimit(RLIMIT_FSIZE, &saved) == 0);
    limit = saved;
    limit.rlim_cur = (rlim_t)info.st_size + 8;
    assert(signal(SIGXFSZ, SIG_IGN) != SIG_ERR);
    assert(setrlimit(RLIMIT_FSIZE, &limit) == 0);
    put.value = (const uint8_t *)"replacement";
    put.value_len = 11;
    assert(zg_write(handle, 2, &put, 1) == ZG_IO_ERROR);
    assert(setrlimit(RLIMIT_FSIZE, &saved) == 0);
    assert(zg_write(handle, 2, &put, 1) == ZG_IO_ERROR);
    assert(zg_flush(handle) == ZG_IO_ERROR);
    assert(zg_close(handle) == ZG_IO_ERROR);
    check(zg_open((const uint8_t *)source, strlen(source), &options, &handle));
    uint8_t output[32];
    size_t required = 0;
    assert(zg_get(handle, &put.key, output, sizeof(output), &required) == ZG_NEEDS_RECOVERY);
    assert(zg_write(handle, 2, &put, 1) == ZG_NEEDS_RECOVERY);
    check(zg_close(handle));
    FILE *file = fopen(segment, "rb");
    assert(file != NULL);
    assert(fseek(file, 0, SEEK_END) == 0);
    long size = ftell(file);
    assert(size > 0);
    rewind(file);
    uint8_t *original = malloc((size_t)size), *after = malloc((size_t)size);
    assert(original && after && fread(original, 1, (size_t)size, file) == (size_t)size);
    assert(fclose(file) == 0);
    path(target, root, "recovered");
    assert(mkdir(target, 0700) == 0);
    char destination[ZG_MAX_PATH_LENGTH];
    path(destination, target, "00000000-00000000-00000000.region");
    assert(mkdir(destination, 0700) == 0);
    assert(zg_recover_region((const uint8_t *)region, strlen(region), (const uint8_t *)region, strlen(region), &options) == ZG_BUSY);
    check(zg_recover_region((const uint8_t *)region, strlen(region), (const uint8_t *)destination, strlen(destination), &options));
    file = fopen(segment, "rb");
    assert(file && fread(after, 1, (size_t)size, file) == (size_t)size && fgetc(file) == EOF);
    assert(memcmp(original, after, (size_t)size) == 0 && fclose(file) == 0);
    free(after);
    free(original);
    check(zg_open((const uint8_t *)target, strlen(target), &options, &handle));
    check(zg_get(handle, &put.key, output, sizeof(output), &required));
    assert(required == 7 && memcmp(output, "durable", 7) == 0);
    check(zg_close(handle));
    path(target, root, "missing");
    handle = NULL;
    assert(zg_open((const uint8_t *)target, strlen(target), &options, &handle) == ZG_NOT_FOUND && handle == NULL);
}

static double duration(const char *text) {
    char *end;
    double seconds = strtod(text, &end);
    assert(end != text && isfinite(seconds) && seconds > 0);
    if (*end == 'm') { seconds *= 60; end++; }
    else if (*end == 'h') { seconds *= 3600; end++; }
    else if (*end == 's') end++;
    assert(*end == 0 && isfinite(seconds));
    return seconds;
}

int main(int argc, char **argv) {
    assert(argc >= 2);
    double seconds = 60;
    size_t max_cycles = 0;
    uint32_t seed = 20261004;
    for (int i = 2; i < argc; i += 2) {
        assert(i + 1 < argc);
        if (!strcmp(argv[i], "--duration")) seconds = duration(argv[i + 1]);
        else {
            char *end;
            unsigned long number = strtoul(argv[i + 1], &end, 10);
            assert(end != argv[i + 1] && *end == 0 && number > 0 && number <= UINT32_MAX);
            if (!strcmp(argv[i], "--cycles")) max_cycles = (size_t)number;
            else if (!strcmp(argv[i], "--ops")) operations = (size_t)number;
            else if (!strcmp(argv[i], "--seed")) seed = (uint32_t)number;
            else assert(!"unknown option");
        }
    }
    char world[ZG_MAX_PATH_LENGTH];
    path(world, argv[1], "world");
    assert(mkdir(world, 0700) == 0);
    for (size_t id = 0; id < CHUNKS; id++) assert(pthread_mutex_init(&locks[id], NULL) == 0);
    for (size_t id = 0; id < AUX_KEYS; id++) assert(pthread_mutex_init(&aux_locks[id], NULL) == 0);
    zg_options options;
    check(zg_options_init(&options));
    options.max_open_regions = 4;
    options.batch_buffer_size = 4096;
    options.max_segment_size = 8192;
    options.compression_threshold = 0;
    options.cache_bytes = 16384;
    options.compact_min_bytes = 16384;
    options.compact_live_percent = 50;
    size_t fd_count = entries("/proc/self/fd"), thread_count = entries("/proc/self/task");
    double started = now();
    uint64_t rotations = 0, compactions = 0;
    size_t cycles = 0;
    do {
        printf("soak seed=%u cycle=%zu\n", seed, cycles);
        fflush(stdout);
        options.compression_threshold = cycles % 2 ? 32 : 0;
        check(zg_open((const uint8_t *)world, strlen(world), &options, &handle));
        verify();
        atomic_store(&stopped, 0);
        Worker workers[WRITERS + READERS + 1];
        pthread_t threads[WRITERS + READERS + 1];
        for (size_t i = 0; i < WRITERS + READERS + 1; i++) {
            workers[i].seed = seed ^ (uint32_t)(cycles * 7919 + i * 104729);
            assert(pthread_create(&threads[i], NULL, i < WRITERS ? writer : i < WRITERS + READERS ? reader : maintenance, &workers[i]) == 0);
        }
        for (size_t i = 0; i < WRITERS; i++) assert(pthread_join(threads[i], NULL) == 0);
        atomic_store(&stopped, 1);
        for (size_t i = WRITERS; i < WRITERS + READERS + 1; i++) assert(pthread_join(threads[i], NULL) == 0);
        check(zg_flush(handle));
        verify();
        zg_stats stats;
        check(zg_stats_get(handle, &stats));
        rotations += stats.segment_rotations;
        compactions += stats.compactions;
        check(zg_compact_async(handle, 0, 0, 0));
        check(zg_close(handle));
        check(zg_open((const uint8_t *)world, strlen(world), &options, &handle));
        verify();
        check(zg_close(handle));
        resources(fd_count, thread_count);
        cycles++;
    } while (max_cycles ? cycles < max_cycles : now() - started < seconds);
    assert(rotations > 0 && compactions > 0);
    failures(argv[1], options);
    resources(fd_count, thread_count);
    for (size_t id = 0; id < CHUNKS; id++) assert(pthread_mutex_destroy(&locks[id]) == 0);
    for (size_t id = 0; id < AUX_KEYS; id++) assert(pthread_mutex_destroy(&aux_locks[id]) == 0);
    printf("soak passed: %zu cycles, %.1fs, %llu rotations, %llu compactions; FDs/threads returned to baseline\n",
           cycles, now() - started, (unsigned long long)rotations, (unsigned long long)compactions);
    return 0;
}
