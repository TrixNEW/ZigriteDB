#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { MAX = 256, ROUNDS = 20 };
static int fds[MAX];
static char buffer[64 * 1024];

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void *syncOne(void *arg) {
    if (fsync(fds[(long)arg])) exit(1);
    return NULL;
}

static int create(const char *dir, const char *name) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) exit(1);
    return fd;
}

int main(int argc, char **argv) {
    int n = argc == 4 ? atoi(argv[2]) : 0;
    size_t per = argc == 4 ? (size_t)atoi(argv[3]) : 0;
    if (n < 1 || n > MAX || per > sizeof buffer) {
        fprintf(stderr, "usage: fsync_probe EMPTY_DIR REGIONS BYTES_PER_REGION (up to 256 and 65536)\n");
        return 2;
    }
    memset(buffer, 7, sizeof buffer);
    for (int i = 0; i < n; i++) {
        char name[16];
        snprintf(name, sizeof name, "r%d", i);
        fds[i] = create(argv[1], name);
    }
    int log = create(argv[1], "log");
    off_t offsets[MAX] = {0}, log_offset = 0;
    double regions = 0, single = 0;
    for (int round = 0; round < ROUNDS; round++) {
        for (int i = 0; i < n; i++) {
            if (pwrite(fds[i], buffer, per, offsets[i]) != (ssize_t)per) return 1;
            offsets[i] += per;
        }
        double started = now();
        pthread_t threads[MAX];
        for (long i = 0; i < n; i++) pthread_create(&threads[i], NULL, syncOne, (void *)i);
        for (int i = 0; i < n; i++) pthread_join(threads[i], NULL);
        regions += now() - started;

        for (int i = 0; i < n; i++) {
            if (pwrite(log, buffer, per, log_offset) != (ssize_t)per) return 1;
            log_offset += per;
        }
        started = now();
        if (fsync(log)) return 1;
        single += now() - started;
    }
    printf("regions=%d bytes/region=%zu  per-region fsyncs (concurrent) %.2f ms   one wal fsync %.2f ms\n", n, per,
           regions / ROUNDS * 1e3, single / ROUNDS * 1e3);
    return 0;
}
