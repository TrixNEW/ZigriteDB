<p align="center">
  <img src="assets/zigritedb_smaller.png" alt="ZigriteDB" width="260">
</p>

<p align="center">
  Embedded world storage built for fast chunk saves and reads.
</p>

ZigriteDB is an embedded Minecraft Bedrock world storage engine written in Zig
for [Quark](https://github.com/Bedrock-Phanatics/Quark). It uses append-only
writes, batched saves, indexed reads, and LZ4 compression for chunk components.

> **In development:** The API and file format may change. Do not use it for
> production worlds yet.

## Build

Requires **Zig 0.16.0** and **Linux** for storage operations.

```sh
zig build -Doptimize=ReleaseSafe
```

## Zig API

Place a checkout at `vendor/zigritedb` and add this to your application's
`build.zig`, using its existing `exe`, `target`, and `optimize`:

```zig
exe.root_module.addImport("zigritedb", b.createModule(.{
    .root_source_file = b.path("vendor/zigritedb/src/root.zig"),
    .target = target,
    .optimize = optimize,
}));
```

Create a `world` directory, then save and read a component:

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

Batches are atomic within one 32×32 chunk region and use increasing IDs.
Writes are buffered by default; call `flush` at save barriers or `close` at
shutdown for durability. For synchronous writes, set
`.shard.durability = .sync`. `deinit` only releases resources. See
[World](src/world/world.zig) for the full Zig API.

## C API

For other languages, link `libzigritedb_native` and include
[zigritedb.h](include/zigritedb.h). The library and header install to
`zig-out/lib` and `zig-out/include`. The current C ABI is version 2; clients
built against version 1 must be rebuilt.

## Benchmarks

Three-run medians for 1,024 saves across 64 chunks, using identical payloads
and save order. Full saves contain four 16 KiB subchunks, biomes, block
entities, and entities; the workload also includes two-component updates.

| Workload | ZigriteDB | PMMP LevelDB fork |
| --- | ---: | ---: |
| Buffered chunk saves | 3,427 saves/s | 4,265 saves/s |
| Synchronous chunk saves | 203 saves/s | 208 saves/s |
| Durable groups of 16 saves | 1,617 saves/s | 2,320 saves/s |
| Seven-component reads, first pass | 11,397 reads/s | 8,529 reads/s |
| Seven-component reads, repeated | 11,407 reads/s | 34,316 reads/s |

**Native code only.** This compares ZigriteDB's C API with the
[C++ LevelDB fork](https://github.com/pmmp/leveldb) used by
[PMMP's PHP extension](https://github.com/pmmp/php-leveldb). PHP calls, NBT
serialization, and the full world provider are excluded. PHP adds overhead,
so these figures are not PMMP server throughput and performance through PHP
will be slower.

Both engines use matching durability modes. PMMP uses its
[raw zlib and 64 KiB block settings](https://github.com/pmmp/PocketMine-MP/blob/stable/src/world/format/io/leveldb/LevelDB.php)
and default 8 MiB block cache; ZigriteDB uses its default 0 MiB value cache.
Buffered saves/s excludes the final durability barrier; grouped saves/s
includes one after every 16 saves. Compression and compaction differ.

Measured on a Ryzen 5 5500 under WSL2 (Linux 6.6, ext4), with Zig 0.16.0
ReleaseSafe. Detailed latencies and memory use are in the
[raw results](tests/bench/results); see the [build script](tests/bench/build_pmmp_native.sh)
and [runner](tests/bench/run_pmmp_native.py) to reproduce the comparison.

## Testing

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build fuzz --fuzz=10000
```

Native fault and workload checks live in [tests/native](tests/native).
See [CI](.github/workflows/ci.yml) for the full verification commands.

## License

See [LICENSE](LICENSE).
