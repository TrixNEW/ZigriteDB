#include <leveldb/c.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint64_t mix(uint64_t h, const char *bytes, size_t len) {
    for (size_t i = 0; i < len; i++) h = (h ^ (uint8_t)bytes[i]) * 1099511628211ull;
    return (h ^ len) * 1099511628211ull;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    char *error = NULL;
    leveldb_options_t *options = leveldb_options_create();
    leveldb_options_set_paranoid_checks(options, 1);
    leveldb_t *db = leveldb_open(options, argv[1], &error);
    if (error) {
        fprintf(stderr, "open: %s\n", error);
        return 1;
    }
    leveldb_readoptions_t *read = leveldb_readoptions_create();
    leveldb_readoptions_set_verify_checksums(read, 1);
    leveldb_iterator_t *it = leveldb_create_iterator(db, read);
    uint64_t hash = 14695981039346656037ull, count = 0;
    for (leveldb_iter_seek_to_first(it); leveldb_iter_valid(it); leveldb_iter_next(it)) {
        size_t kl, vl;
        const char *k = leveldb_iter_key(it, &kl), *v = leveldb_iter_value(it, &vl);
        hash = mix(mix(hash, k, kl), v, vl);
        count++;
    }
    leveldb_iter_get_error(it, &error);
    if (error) {
        fprintf(stderr, "iterate: %s\n", error);
        return 1;
    }
    leveldb_iter_destroy(it);
    if (argc > 2 && !strcmp(argv[2], "write")) {
        leveldb_writeoptions_t *write = leveldb_writeoptions_create();
        leveldb_writeoptions_set_sync(write, 1);
        leveldb_put(db, write, "zigrite-check", 13, "ok", 2, &error);
        if (error) return 1;
        leveldb_close(db);
        db = leveldb_open(options, argv[1], &error);
        if (error) return 1;
        size_t len = 0;
        char *value = leveldb_get(db, read, "zigrite-check", 13, &len, &error);
        if (error || !value || len != 2) return 1;
        leveldb_free(value);
        leveldb_delete(db, write, "zigrite-check", 13, &error);
        if (error) return 1;
    }
    leveldb_close(db);
    printf("%llu %016llx\n", (unsigned long long)count, (unsigned long long)hash);
    return 0;
}
