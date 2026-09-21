#include "harness.h"
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>

enum { AREA_ANCHORS = 16 };

static void makeDir(const char *path) {
    if (mkdir(path, 0700)) exit(1);
}

/* Times AREA_ANCHORS NxN chunk-area scans as one sample each; misses are expected. */
static void scanAreas(zg_handle *handle, const char *label, int size, uint32_t *random, uint8_t *output) {
    double samples[AREA_ANCHORS];
    double phase_started = now();
    for (int anchor = 0; anchor < AREA_ANCHORS; ++anchor) {
        *random = *random * 1664525u + 1013904223u;
        int origin_x = (int)(*random % 200), origin_z = (int)((*random >> 16) % 200);
        double before = now();
        for (int dx = 0; dx < size; ++dx) {
            for (int dz = 0; dz < size; ++dz) {
                zg_key key = {0, origin_x + dx, origin_z + dz, 0, 1};
                size_t required;
                int status = zg_get(handle, &key, output, 1024, &required);
                if (status != ZG_OK && status != ZG_NOT_FOUND) exit(1);
            }
        }
        samples[anchor] = now() - before;
    }
    report(label, samples, AREA_ANCHORS, now() - phase_started);
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: native_bench EMPTY_DIRECTORY BATCHES sync|group|buffered\n");
        return 1;
    }
    char *end;
    unsigned long parsed = strtoul(argv[2], &end, 10);
    if (*end || parsed < 128 || parsed > 1000000 || parsed % 16) return 1;
    size_t count = (size_t)parsed;
    int grouped = strcmp(argv[3], "group") == 0;
    int buffered = strcmp(argv[3], "buffered") == 0;
    if (!grouped && !buffered && strcmp(argv[3], "sync")) return 1;
    double *samples = malloc(count * sizeof(*samples));
    if (!samples) return 1;
    zg_options options;
    check(zg_options_init(&options));
    options.max_open_shards = 8;
    options.max_segment_size = 16 * 1024 * 1024;
    options.buffered = grouped || buffered;
    zg_handle *handle;
    check(zg_open((const uint8_t *)argv[1], strlen(argv[1]), &options, &handle));
    uint8_t values[4][1024], output[1024];
    uint32_t random = 42;
    for (size_t c = 0; c < 4; ++c) {
        for (size_t i = 0; i < sizeof(values[c]); ++i) {
            random = random * 1664525u + 1013904223u;
            values[c][i] = i < 512 ? (uint8_t)c : (uint8_t)(random >> 24);
        }
    }
    zg_operation operations[64];
    zg_batch batches[16];
    size_t step = grouped ? 16 : 1, calls = 0;
    double started = now();
    for (size_t i = 0; i < count; i += step) {
        for (size_t j = 0; j < step; ++j) {
            int x = (int)(((i + j) / 16 % 8) * 32 + (i + j) % 16);
            for (size_t c = 0; c < 4; ++c) {
                operations[j * 4 + c] = (zg_operation){
                    {0, x, 0, 0, (uint32_t)c + 1}, ZG_PUT, values[c], sizeof(values[c])
                };
            }
            batches[j] = (zg_batch){i + j + 1, operations + j * 4, 4};
        }
        double before = now();
        if (grouped) check(zg_write_group(handle, batches, step));
        else check(zg_write(handle, i + 1, operations, 4));
        samples[calls++] = now() - before;
    }
    double elapsed = now() - started;
    printf("{\"mode\":\"%s\",\"batches\":%zu,\"raw_value_bytes\":%zu,", argv[3], count, count * 4096);
    report("save_calls", samples, calls, elapsed);

    /* Contrasts with save_calls' 4-component batches; a disjoint chunk range avoids collisions. */
    started = now();
    for (size_t i = 0; i < count; ++i) {
        zg_operation single = {{0, (int)(10000 + i % 4096), 0, 0, 5}, ZG_PUT, values[0], sizeof(values[0])};
        double before = now();
        check(zg_write(handle, count + i + 1, &single, 1));
        samples[i] = now() - before;
    }
    printf(",");
    report("single_component_writes", samples, count, now() - started);

    started = now();
    check(zg_flush(handle));
    printf(",\"final_flush_ms\":%.3f,", (now() - started) * 1e3);

    for (int phase = 0; phase < 2; ++phase) {
        started = now();
        for (size_t i = 0; i < count; ++i) {
            random = random * 1664525u + 1013904223u;
            unsigned chunk = phase ? random % 128 : 0;
            zg_key key = {0, (int32_t)(chunk / 16 * 32 + chunk % 16), 0, 0, 1};
            size_t required;
            double before = now();
            check(zg_get(handle, &key, output, sizeof(output), &required));
            samples[i] = now() - before;
            if (required != sizeof(output) || memcmp(output, values[0], required)) return 1;
        }
        report(phase ? "random_reads" : "hot_reads", samples, count, now() - started);
        printf(",");
    }

    /* All 4 components of the hot chunk, timed as one unit. */
    started = now();
    for (size_t i = 0; i < count; ++i) {
        double before = now();
        for (uint32_t c = 1; c <= 4; ++c) {
            zg_key key = {0, 0, 0, 0, c};
            size_t required;
            check(zg_get(handle, &key, output, sizeof(output), &required));
        }
        samples[i] = now() - before;
    }
    report("full_chunk_reads", samples, count, now() - started);
    printf(",");

    scanAreas(handle, "area_reads_8x8", 8, &random, output);
    printf(",");
    scanAreas(handle, "area_reads_16x16", 16, &random, output);
    printf(",");
    scanAreas(handle, "area_reads_32x32", 32, &random, output);
    printf(",");

    started = now();
    for (int x = 0; x < 8; ++x) check(zg_compact_async(handle, 0, x, 0));
    for (size_t i = 0; i < count; ++i) {
        zg_key key = {0, (int32_t)(i % 8 * 32), 0, 0, 1};
        size_t required;
        double before = now();
        check(zg_get(handle, &key, output, sizeof(output), &required));
        samples[i] = now() - before;
        if (required != sizeof(output) || memcmp(output, values[0], required)) return 1;
    }
    report("reads_during_compaction", samples, count, now() - started);
    check(zg_maintenance_wait(handle));
    printf(",\"compaction_ms\":%.3f,", (now() - started) * 1e3);

    /* Steady-state reads of the same 8 keys, now that compaction has finished. */
    started = now();
    for (size_t i = 0; i < count; ++i) {
        zg_key key = {0, (int32_t)(i % 8 * 32), 0, 0, 1};
        size_t required;
        double before = now();
        check(zg_get(handle, &key, output, sizeof(output), &required));
        samples[i] = now() - before;
        if (required != sizeof(output) || memcmp(output, values[0], required)) return 1;
    }
    report("post_compaction_reads", samples, count, now() - started);
    /* Snapshot before closing: reopening below hands us a fresh Handle with its own zeroed Stats. */
    reportStats(handle);

    check(zg_close(handle));
    started = now();
    check(zg_open((const uint8_t *)argv[1], strlen(argv[1]), &options, &handle));
    for (int x = 0; x < 8; ++x) {
        uint64_t last;
        check(zg_last_batch_id(handle, 0, x, 0, &last));
    }
    printf(",\"reopen_and_replay_ms\":%.3f", (now() - started) * 1e3);
    check(zg_close(handle));

    /* Contrast with reopen_and_replay_ms above: a small, freshly created region. */
    {
        char path[4160];
        if ((size_t)snprintf(path, sizeof(path), "%s-small", argv[1]) >= sizeof(path)) return 1;
        makeDir(path);
        zg_options small_options;
        check(zg_options_init(&small_options));
        zg_handle *small;
        check(zg_open((const uint8_t *)path, strlen(path), &small_options, &small));
        uint8_t small_value[64];
        memset(small_value, 7, sizeof(small_value));
        for (int b = 1; b <= 8; ++b) {
            zg_operation op = {{0, b, 0, 0, 1}, ZG_PUT, small_value, sizeof(small_value)};
            check(zg_write(small, (uint64_t)b, &op, 1));
        }
        check(zg_close(small));
        double small_started = now();
        check(zg_open((const uint8_t *)path, strlen(path), &small_options, &small));
        printf(",\"reopen_small_region_ms\":%.3f", (now() - small_started) * 1e3);
        check(zg_close(small));
    }

    /* Forces one region out of the open-shard cache, then times reopening it. */
    {
        char path[4160];
        if ((size_t)snprintf(path, sizeof(path), "%s-evict", argv[1]) >= sizeof(path)) return 1;
        makeDir(path);
        zg_options evict_options;
        check(zg_options_init(&evict_options));
        evict_options.max_open_shards = 2;
        zg_handle *evict;
        check(zg_open((const uint8_t *)path, strlen(path), &evict_options, &evict));
        uint8_t evict_value[64];
        memset(evict_value, 9, sizeof(evict_value));
        for (int region = 0; region < 3; ++region) {
            zg_operation op = {{0, region * 32, 0, 0, 1}, ZG_PUT, evict_value, sizeof(evict_value)};
            check(zg_write(evict, 1, &op, 1));
        }
        zg_key evicted_key = {0, 0, 0, 0, 1};
        size_t required;
        double evict_started = now();
        check(zg_get(evict, &evicted_key, output, sizeof(output), &required));
        printf(",\"reopen_after_eviction_ms\":%.3f", (now() - evict_started) * 1e3);
        check(zg_close(evict));
    }

    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage)) return 1;
    printf(",\"peak_rss_kib\":%ld,\"cpu_seconds\":%.3f}\n", usage.ru_maxrss,
           usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6);
    free(samples);
    return 0;
}
