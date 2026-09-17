<p align="center">
  <img src="assets/zigritedb_smaller.png" alt="ZigriteDB" width="260">
</p>

<p align="center">
  Embedded world storage built for fast chunk saves and reads.
</p>

ZigriteDB is a storage engine for Minecraft Bedrock world data, written in Zig.
It stores chunk components independently and combines append-only writes,
batched saves, and LZ4 compression to reduce work on the save path. Originally
built for [Quark](https://github.com/Bedrock-Phanatics/Quark), it exposes a C API
for integration with other runtimes.

**Status:** Active development. Storage currently supports Linux; the API and
on-disk format may change. Not yet recommended for production worlds.

## Performance

- **Append-only saves.** Write changed components without rewriting an entire chunk.
- **Batched saves.** Group up to 64 batches in one region behind a final sync.
- **Indexed reads.** Locate values through an in-memory index and read into caller-owned buffers.
- **LZ4 compression.** Compress values when it reduces their stored size.
- **Regional concurrency.** Writes to different regions can proceed concurrently. Reads continue during compaction; writes to that region wait.
- **Configurable memory.** Bound open shards, index entries, and batch buffers. Native writers reuse buffers between calls.

## Build

Requires **Zig 0.16.0** and **Linux** for storage operations.

```sh
zig build -Doptimize=ReleaseSafe
```

The build installs libraries in `zig-out/lib` and the C header in `zig-out/include`.
Link against `libzigritedb_native` to embed the engine in your application.

## API

Open a world, save a component, and read it back. This example uses a new, empty
`world` directory and batch ID `1`.

```c
#include <stdio.h>
#include "zigritedb.h"

int main(void) {
    zg_options options;
    int status = zg_options_init(&options);
    if (status != ZG_OK) return 1;

    zg_handle *world = NULL;
    status = zg_open((const uint8_t *)"world", 5, &options, &world);
    if (status != ZG_OK) {
        fprintf(stderr, "%s\n", zg_status_message(status));
        return 1;
    }

    const uint8_t data[] = {1, 2, 3, 4};
    zg_operation save = {
        .key = {.chunk_x = 4, .chunk_z = 8, .component = ZG_METADATA},
        .remove = ZG_PUT,
        .value = data,
        .value_len = sizeof(data),
    };

    status = zg_write(world, 1, &save, 1);
    if (status == ZG_OK) {
        uint8_t output[64];
        size_t required = 0;
        status = zg_get(world, &save.key, output, sizeof(output), &required);
    }

    int close_status = zg_close(world);
    if (status == ZG_OK) status = close_status;
    if (status != ZG_OK) fprintf(stderr, "%s\n", zg_status_message(status));
    return status == ZG_OK ? 0 : 1;
}
```

Each batch is atomic and belongs to one 32×32 chunk region. Batch IDs increase
per region; use `zg_last_batch_id` to resume after reopening and coordinate IDs
between writers. Values are application-owned component bytes.

| Operation | API |
| --- | --- |
| Save or delete components | `zg_write` |
| Save multiple batches with a shared final sync | `zg_write_group` |
| Read a component | `zg_get` |
| Flush buffered saves | `zg_flush` |
| Queue background compaction | `zg_compact_async` |
| Wait for queued maintenance | `zg_maintenance_wait` |

Writes sync by default. Buffered writes can be lost until a successful flush,
eviction, or close. Save groups sync before returning success, but a failed
group can leave earlier batches committed. A write error does not guarantee
that nothing reached disk.

`zg_get` reports the required buffer size. Finish all calls before `zg_close`,
which drains maintenance and frees the handle even on error. See the
[public header](include/zigritedb.h) for options, limits, and the full API.

## Benchmarks

Measure save latency, reads, compaction, replay, CPU usage, memory, and database
size on your target filesystem:

```sh
zig build bench -Doptimize=ReleaseSafe
python3 tests/bench/run.py --directory /path/to/benchmark/filesystem
```

The runner uses temporary databases and outputs JSON for synchronous, grouped,
and buffered saves. Group samples contain 16 batches per call; buffered saves
sync at the end. Results are synthetic. Use equivalent workloads and durability settings when
comparing engines.

## Testing

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build fuzz --fuzz=10000
```

Run the C API, crash, I/O failure, and restart checks on Linux x86-64:

```sh
zig build native-test
python3 tests/native/native_faults.py zig-out/lib/libzigritedb_native.so zig-out/bin/native_smoke
python3 tests/native/native_workloads.py zig-out/lib/libzigritedb_native.so
```

## License

See [LICENSE](LICENSE).
