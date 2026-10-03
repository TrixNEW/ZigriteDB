// Extracts overworld chunk records from a Bedrock LevelDB world into a flat file for world_bench.
// Format: "ZGDS" u32 chunks, then per chunk: i32 x, i32 z, u16 count, count * (u8 tag, i8 y, u32 len, bytes).
#include <leveldb/c.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int32_t x, z;
    uint8_t tag;
    int8_t y;
    uint32_t len;
    char *value;
} Record;

static int wanted(uint8_t tag) {
    return tag == 0x2f || tag == 0x2b || tag == 0x31 || tag == 0x32 || tag == 0x2c || tag == 0x76;
}

static int byChunk(const void *a, const void *b) {
    const Record *l = a, *r = b;
    if (l->x != r->x) return l->x < r->x ? -1 : 1;
    if (l->z != r->z) return l->z < r->z ? -1 : 1;
    if (l->tag != r->tag) return l->tag < r->tag ? -1 : 1;
    return l->y - r->y;
}

static void put(FILE *out, const void *bytes, size_t len) {
    if (fwrite(bytes, 1, len, out) != len) exit(1);
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: dataset LEVELDB_DIR OUTPUT SIDE\n  keeps a SIDE x SIDE chunk square at the world's centre\n");
        return 1;
    }
    int side = atoi(argv[3]);
    char *error = NULL;
    leveldb_options_t *options = leveldb_options_create();
    leveldb_t *db = leveldb_open(options, argv[1], &error);
    if (error) {
        fprintf(stderr, "%s\n", error);
        return 1;
    }
    leveldb_readoptions_t *read = leveldb_readoptions_create();
    leveldb_iterator_t *it = leveldb_create_iterator(db, read);

    long long sum_x = 0, sum_z = 0, versions = 0;
    for (leveldb_iter_seek_to_first(it); leveldb_iter_valid(it); leveldb_iter_next(it)) {
        size_t kl;
        const uint8_t *k = (const uint8_t *)leveldb_iter_key(it, &kl);
        if (kl != 9 || k[8] != 0x2c) continue;
        int32_t x, z;
        memcpy(&x, k, 4);
        memcpy(&z, k + 4, 4);
        sum_x += x;
        sum_z += z;
        versions++;
    }
    if (!versions) return 1;
    int32_t min_x = (int32_t)(sum_x / versions) - side / 2, min_z = (int32_t)(sum_z / versions) - side / 2;

    size_t count = 0, capacity = 1 << 16;
    Record *records = malloc(capacity * sizeof(*records));
    for (leveldb_iter_seek_to_first(it); leveldb_iter_valid(it); leveldb_iter_next(it)) {
        size_t kl, vl;
        const uint8_t *k = (const uint8_t *)leveldb_iter_key(it, &kl);
        if (kl != 9 && kl != 10) continue;
        uint8_t tag = k[8];
        if (!wanted(tag) || (kl == 10) != (tag == 0x2f)) continue;
        int32_t x, z;
        memcpy(&x, k, 4);
        memcpy(&z, k + 4, 4);
        if (x < min_x || x >= min_x + side || z < min_z || z >= min_z + side) continue;
        const char *v = leveldb_iter_value(it, &vl);
        if (count == capacity) records = realloc(records, (capacity *= 2) * sizeof(*records));
        Record *r = &records[count++];
        *r = (Record){x, z, tag, kl == 10 ? (int8_t)k[9] : 0, (uint32_t)vl, malloc(vl ? vl : 1)};
        memcpy(r->value, v, vl);
    }
    qsort(records, count, sizeof(*records), byChunk);

    FILE *out = fopen(argv[2], "wb");
    if (!out) return 1;
    uint32_t chunks = 0;
    put(out, "ZGDS", 4);
    put(out, &chunks, 4);
    size_t bytes = 0;
    for (size_t i = 0; i < count;) {
        size_t j = i;
        while (j < count && records[j].x == records[i].x && records[j].z == records[i].z) j++;
        uint16_t n = (uint16_t)(j - i);
        put(out, &records[i].x, 4);
        put(out, &records[i].z, 4);
        put(out, &n, 2);
        for (; i < j; i++) {
            put(out, &records[i].tag, 1);
            put(out, &records[i].y, 1);
            put(out, &records[i].len, 4);
            put(out, records[i].value, records[i].len);
            bytes += records[i].len;
        }
        chunks++;
    }
    fseek(out, 4, SEEK_SET);
    put(out, &chunks, 4);
    fclose(out);
    fprintf(stderr, "%u chunks, %zu records, %zu value bytes\n", chunks, count, bytes);
    return 0;
}
