#ifndef ZIGRITEDB_BENCH_HARNESS_H
#define ZIGRITEDB_BENCH_HARNESS_H
#define _POSIX_C_SOURCE 200809L
#include "zigritedb.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static inline void check(int status) {
    if (status != ZG_OK) {
        fprintf(stderr, "%s\n", zg_status_message(status));
        exit(1);
    }
}

static inline double now(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time)) exit(1);
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static inline int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

/* p999_us is the 99.9th percentile. */
static inline void report(const char *name, double *samples, size_t count, double elapsed) {
    qsort(samples, count, sizeof(*samples), compare);
    printf("\"%s\":{\"calls\":%zu,\"calls_per_second\":%.2f,"
           "\"p50_us\":%.2f,\"p95_us\":%.2f,\"p99_us\":%.2f,\"p999_us\":%.2f}",
           name, count, count / elapsed, samples[(count - 1) / 2] * 1e6,
           samples[(count - 1) * 95 / 100] * 1e6, samples[(count - 1) * 99 / 100] * 1e6,
           samples[(count - 1) * 999 / 1000] * 1e6);
}

static inline void reportStats(zg_handle *handle) {
    zg_stats stats;
    check(zg_stats_get(handle, &stats));
    printf(",\"stats\":{"
           "\"get_calls\":%" PRIu64 ",\"writes\":%" PRIu64 ",\"records_written\":%" PRIu64 ","
           "\"raw_bytes_written\":%" PRIu64 ",\"compressed_bytes_written\":%" PRIu64 ","
           "\"disk_reads\":%" PRIu64 ",\"bytes_read\":%" PRIu64 ","
           "\"fsync_count\":%" PRIu64 ",\"fsync_duration_ns\":%" PRIu64 ","
           "\"segment_rotations\":%" PRIu64 ","
           "\"compactions\":%" PRIu64 ",\"compaction_input_bytes\":%" PRIu64 ","
           "\"compaction_output_bytes\":%" PRIu64 ",\"compaction_duration_ns\":%" PRIu64 ","
           "\"recovery_attempts\":%" PRIu64 ",\"recovery_errors\":%" PRIu64 ","
           "\"cache_hits\":%" PRIu64 ",\"cache_misses\":%" PRIu64 ",\"cache_evictions\":%" PRIu64 "}",
           stats.get_calls, stats.writes, stats.records_written,
           stats.raw_bytes_written, stats.compressed_bytes_written,
           stats.disk_reads, stats.bytes_read,
           stats.fsync_count, stats.fsync_duration_ns,
           stats.segment_rotations,
           stats.compactions, stats.compaction_input_bytes,
           stats.compaction_output_bytes, stats.compaction_duration_ns,
           stats.recovery_attempts, stats.recovery_errors,
           stats.cache_hits, stats.cache_misses, stats.cache_evictions);
}

#endif
