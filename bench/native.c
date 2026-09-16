#define _POSIX_C_SOURCE 200809L
#include "zigritedb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>

static void check(int status) {
    if (status != ZG_OK) {
        fprintf(stderr, "%s\n", zg_status_message(status));
        exit(1);
    }
}

static double now(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time)) exit(1);
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void report(const char *name, double *samples, size_t count, double elapsed) {
    qsort(samples, count, sizeof(*samples), compare);
    printf("\"%s\":{\"calls\":%zu,\"calls_per_second\":%.2f,"
           "\"p50_us\":%.2f,\"p95_us\":%.2f,\"p99_us\":%.2f,\"p999_us\":%.2f}",
           name, count, count / elapsed, samples[(count - 1) / 2] * 1e6,
           samples[(count - 1) * 95 / 100] * 1e6, samples[(count - 1) * 99 / 100] * 1e6,
           samples[(count - 1) * 999 / 1000] * 1e6);
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
    printf(",\"compaction_ms\":%.3f", (now() - started) * 1e3);
    check(zg_close(handle));
    started = now();
    check(zg_open((const uint8_t *)argv[1], strlen(argv[1]), &options, &handle));
    for (int x = 0; x < 8; ++x) {
        uint64_t last;
        check(zg_last_batch_id(handle, 0, x, 0, &last));
    }
    printf(",\"reopen_and_replay_ms\":%.3f", (now() - started) * 1e3);
    check(zg_close(handle));
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage)) return 1;
    printf(",\"peak_rss_kib\":%ld,\"cpu_seconds\":%.3f}\n", usage.ru_maxrss,
           usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6);
    free(samples);
    return 0;
}
