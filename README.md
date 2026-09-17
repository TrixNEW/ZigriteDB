<p align="center">
  <img src="assets/zigritedb_smaller.png" alt="ZigriteDB" width="260">
</p>

<p align="center">
  Embedded world storage built for fast chunk saves and reads.
</p>

ZigriteDB is a storage engine for Minecraft Bedrock world data, written in Zig.
It stores chunk components independently and combines append-only writes,
batched saves, and LZ4 compression to reduce work on the save path. Originally
built for [Quark](https://github.com/Bedrock-Phanatics/Quark), it provides a native
Zig API and a C ABI for integration with other languages.

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
Zig applications import the module directly.

## Zig API

With a checkout at `vendor/zigritedb`, add the module to your application's
`build.zig`, using its existing `target`, `optimize`, and `exe` values:

```zig
exe.root_module.addImport("zigritedb", b.createModule(.{
    .root_source_file = b.path("vendor/zigritedb/src/root.zig"),
    .target = target,
    .optimize = optimize,
}));
```

Create a `world` directory before running this example. It opens the world,
saves a chunk component, and reads it into a caller-owned buffer.

```zig
const std = @import("std");
const db = @import("zigritedb");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try std.Io.Dir.cwd().openDir(io, "world", .{});
    defer dir.close(io);
    var world = try db.World.open(allocator, io, dir, .{});
    defer world.deinit();

    const key: db.Key = .{
        .dimension = 0,
        .chunk_x = 4,
        .chunk_z = 8,
        .component = .metadata,
    };
    const last_id = (try world.lastBatchId(key.region())) orelse 0;
    const data = "chunk data";
    _ = try world.write(.{ .entries = &.{.{
        .key = key,
        .header = .{
            .kind = .put,
            .batch_id = try std.math.add(u64, last_id, 1),
            .stored_len = data.len,
            .raw_len = data.len,
        },
        .value = data,
    }} });

    var buffer: [64]u8 = undefined;
    const saved = (try world.get(key, &buffer)) orelse return error.NotFound;
    std.debug.print("{s}\n", .{saved});
    try world.close();
}
```

Each `WriteBatch` is atomic and belongs to one 32×32 chunk region. Batch IDs
increase per region; `World.lastBatchId` lets a writer resume after reopening.
Concurrent writers must coordinate IDs. Values are application-owned component
bytes; this example stores them without compression.

| Operation | Zig API |
| --- | --- |
| Save or delete components | `World.write` |
| Save multiple batches with a shared final sync | `World.writeGroup` |
| Read a component | `World.get` |
| Read with required buffer size | `World.getSized` |
| Flush buffered saves | `World.flush` |
| Compact a region | `World.compact` |

Use `World` for region routing and caching, or `Store` to manage a single region.
See the [module exports](src/root.zig) and [world API](src/world/world.zig) for
available types and options.

Writes sync by default. Buffered writes can be lost until a successful flush,
eviction, or close. Save groups sync before returning success, but a failed
group can leave earlier batches committed. A write error does not guarantee
that nothing reached disk. Use `close` to flush and report errors; `deinit`
releases resources without flushing.

## C ABI

For C, PHP, and other runtimes, link against `libzigritedb_native` and include
[zigritedb.h](include/zigritedb.h). The C ABI exposes the same engine through
`zg_open`, `zg_write`, `zg_write_group`, `zg_get`, and `zg_close`.

The native handle also manages background compaction through `zg_compact_async`
and `zg_maintenance_wait`. Finish all calls before `zg_close`, which drains
maintenance and frees the handle even on error. Zig callers use the Zig API
directly without C bindings.

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
