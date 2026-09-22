#include "harness.h"
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>

enum { MAX_THREADS = 32 };

typedef struct {
    zg_handle *handle;
    int thread_index;
    size_t iterations;
    zg_key key;
    int region_x;
    atomic_ullong *next_batch_id;
    pthread_mutex_t *submit_lock;
    double *samples;
    int library_ids;
    int failed;
} Task;

static void *readTask(void *arg) {
    Task *task = arg;
    uint8_t output[64];
    for (size_t i = 0; i < task->iterations; ++i) {
        size_t required;
        double before = now();
        int status = zg_get(task->handle, &task->key, output, sizeof(output), &required);
        task->samples[i] = now() - before;
        if (status != ZG_OK && status != ZG_NOT_FOUND) {
            task->failed = 1;
            return NULL;
        }
    }
    return NULL;
}

static void *writeTask(void *arg) {
    Task *task = arg;
    uint8_t value[64];
    memset(value, (unsigned char)task->thread_index, sizeof(value));
    for (size_t i = 0; i < task->iterations; ++i) {
        zg_operation op = {{0, task->region_x, (int32_t)i, 0, 1}, ZG_PUT, value, sizeof(value)};
        double before, elapsed;
        int status;
        if (task->library_ids) {
            before = now();
            status = zg_write(task->handle, 0, &op, 1);
            elapsed = now() - before;
        } else if (task->submit_lock) {
            pthread_mutex_lock(task->submit_lock);
            unsigned long long id = atomic_fetch_add(task->next_batch_id, 1ULL);
            before = now();
            status = zg_write(task->handle, id, &op, 1);
            elapsed = now() - before;
            pthread_mutex_unlock(task->submit_lock);
        } else {
            before = now();
            status = zg_write(task->handle, (uint64_t)(i + 1), &op, 1);
            elapsed = now() - before;
        }
        task->samples[i] = elapsed;
        if (status != ZG_OK) {
            task->failed = 1;
            return NULL;
        }
    }
    return NULL;
}

static double runThreads(void *(*fn)(void *), Task *tasks, int threads) {
    pthread_t handles[MAX_THREADS];
    double started = now();
    for (int t = 0; t < threads; ++t) {
        if (pthread_create(&handles[t], NULL, fn, &tasks[t])) exit(1);
    }
    for (int t = 0; t < threads; ++t) pthread_join(handles[t], NULL);
    double elapsed = now() - started;
    for (int t = 0; t < threads; ++t) {
        if (tasks[t].failed) exit(1);
    }
    return elapsed;
}

static void reportMerged(const char *label, Task *tasks, int threads, double elapsed) {
    size_t total = 0;
    for (int t = 0; t < threads; ++t) total += tasks[t].iterations;
    double *merged = malloc(total * sizeof(*merged));
    if (!merged) exit(1);
    size_t offset = 0;
    for (int t = 0; t < threads; ++t) {
        memcpy(merged + offset, tasks[t].samples, tasks[t].iterations * sizeof(*merged));
        offset += tasks[t].iterations;
    }
    report(label, merged, offset, elapsed);
    free(merged);
}

static void makeDir(const char *path) {
    if (mkdir(path, 0700)) exit(1);
}

static uint64_t cache_bytes = 0;

static zg_handle *openScenario(const char *base, const char *suffix, uint32_t max_open_shards) {
    char path[4160];
    if ((size_t)snprintf(path, sizeof(path), "%s-%s", base, suffix) >= sizeof(path)) exit(1);
    makeDir(path);
    zg_options options;
    check(zg_options_init(&options));
    options.max_open_shards = max_open_shards;
    options.cache_bytes = cache_bytes;
    zg_handle *handle;
    check(zg_open((const uint8_t *)path, strlen(path), &options, &handle));
    return handle;
}

static void sameRegionReads(const char *base, size_t total_iterations, int threads) {
    zg_handle *handle = openScenario(base, "same-region-reads", 4);
    uint8_t value[64];
    memset(value, 5, sizeof(value));
    zg_operation seed = {{0, 0, 0, 0, 1}, ZG_PUT, value, sizeof(value)};
    check(zg_write(handle, 1, &seed, 1));

    size_t per_thread = total_iterations / (size_t)threads;
    if (per_thread < 1) per_thread = 1;
    Task tasks[MAX_THREADS];
    for (int t = 0; t < threads; ++t) {
        tasks[t] = (Task){
            .handle = handle, .thread_index = t, .iterations = per_thread,
            .key = {0, 0, 0, 0, 1}, .samples = malloc(per_thread * sizeof(double)),
        };
        if (!tasks[t].samples) exit(1);
    }
    double elapsed = runThreads(readTask, tasks, threads);
    reportMerged("same_region_parallel_reads", tasks, threads, elapsed);
    for (int t = 0; t < threads; ++t) free(tasks[t].samples);
    check(zg_close(handle));
}

static void crossRegionReads(const char *base, size_t total_iterations, int threads) {
    zg_handle *handle = openScenario(base, "cross-region-reads", (uint32_t)threads);
    uint8_t value[64];
    memset(value, 6, sizeof(value));
    for (int t = 0; t < threads; ++t) {
        zg_operation seed = {{0, t * 32, 0, 0, 1}, ZG_PUT, value, sizeof(value)};
        check(zg_write(handle, 1, &seed, 1));
    }

    size_t per_thread = total_iterations / (size_t)threads;
    if (per_thread < 1) per_thread = 1;
    Task tasks[MAX_THREADS];
    for (int t = 0; t < threads; ++t) {
        tasks[t] = (Task){
            .handle = handle, .thread_index = t, .iterations = per_thread,
            .key = {0, t * 32, 0, 0, 1}, .samples = malloc(per_thread * sizeof(double)),
        };
        if (!tasks[t].samples) exit(1);
    }
    double elapsed = runThreads(readTask, tasks, threads);
    reportMerged("cross_region_parallel_reads", tasks, threads, elapsed);
    for (int t = 0; t < threads; ++t) free(tasks[t].samples);
    check(zg_close(handle));
}

static uint64_t fsyncCount(zg_handle *handle) {
    zg_stats stats;
    check(zg_stats_get(handle, &stats));
    return stats.fsync_count;
}

static void sameRegionWrites(const char *base, size_t total_iterations, int threads, int library_ids) {
    const char *label = library_ids ? "concurrent_writes_same_region_next_id" : "concurrent_writes_same_region";
    zg_handle *handle = openScenario(base, label, 4);
    size_t per_thread = total_iterations / (size_t)threads;
    if (per_thread < 1) per_thread = 1;

    pthread_mutex_t submit_lock = PTHREAD_MUTEX_INITIALIZER;
    atomic_ullong next_batch_id = 1;
    Task tasks[MAX_THREADS];
    for (int t = 0; t < threads; ++t) {
        tasks[t] = (Task){
            .handle = handle, .thread_index = t, .iterations = per_thread,
            .region_x = 0, .next_batch_id = &next_batch_id, .submit_lock = library_ids ? NULL : &submit_lock,
            .samples = malloc(per_thread * sizeof(double)), .library_ids = library_ids,
        };
        if (!tasks[t].samples) exit(1);
    }
    uint64_t fsyncs = fsyncCount(handle);
    double elapsed = runThreads(writeTask, tasks, threads);
    reportMerged(label, tasks, threads, elapsed);
    printf(",\"%s_fsyncs\":%llu", label, (unsigned long long)(fsyncCount(handle) - fsyncs));
    for (int t = 0; t < threads; ++t) free(tasks[t].samples);
    check(zg_close(handle));
}

static void differentRegionWrites(const char *base, size_t total_iterations, int threads) {
    zg_handle *handle = openScenario(base, "different-region-writes", (uint32_t)threads);
    size_t per_thread = total_iterations / (size_t)threads;
    if (per_thread < 1) per_thread = 1;

    Task tasks[MAX_THREADS];
    for (int t = 0; t < threads; ++t) {
        tasks[t] = (Task){
            .handle = handle, .thread_index = t, .iterations = per_thread,
            .region_x = t * 32, .samples = malloc(per_thread * sizeof(double)),
        };
        if (!tasks[t].samples) exit(1);
    }
    uint64_t fsyncs = fsyncCount(handle);
    double elapsed = runThreads(writeTask, tasks, threads);
    reportMerged("concurrent_writes_different_regions", tasks, threads, elapsed);
    printf(",\"concurrent_writes_different_regions_fsyncs\":%llu", (unsigned long long)(fsyncCount(handle) - fsyncs));
    for (int t = 0; t < threads; ++t) free(tasks[t].samples);
    check(zg_close(handle));
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) {
        fprintf(stderr, "usage: native_bench_concurrency EMPTY_DIRECTORY BATCHES THREADS [CACHE_MB]\n");
        return 1;
    }
    if (argc == 5) cache_bytes = strtoull(argv[4], NULL, 10) * 1024 * 1024;
    char *end;
    unsigned long batches = strtoul(argv[2], &end, 10);
    if (*end || batches < 16) return 1;
    end = NULL;
    unsigned long thread_arg = strtoul(argv[3], &end, 10);
    if (*end || thread_arg < 1 || thread_arg > MAX_THREADS) return 1;
    int threads = (int)thread_arg;

    printf("{\"threads\":%d,", threads);
    sameRegionReads(argv[1], (size_t)batches, threads);
    printf(",");
    crossRegionReads(argv[1], (size_t)batches, threads);
    printf(",");
    sameRegionWrites(argv[1], (size_t)batches, threads, 0);
    printf(",");
    sameRegionWrites(argv[1], (size_t)batches, threads, 1);
    printf(",");
    differentRegionWrites(argv[1], (size_t)batches, threads);
    printf("}\n");
    return 0;
}
