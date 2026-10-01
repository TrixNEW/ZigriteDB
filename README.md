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

Checksums use the CPU's CRC32C instruction when the target has it. Builds for
other machines should target at least `-Dcpu=x86_64_v2`; baseline x86_64 falls
back to a much slower table.

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

Regions are compacted in the background while reads and writes continue. The
C API does this automatically once a region is mostly stale; Zig users can call
`compact` or set `World.compactor` to schedule it themselves.

## C API

For other languages, link `libzigritedb_native` and include
[zigritedb.h](include/zigritedb.h). The library and header install to
`zig-out/lib` and `zig-out/include`. The current C ABI is version 2; clients
built against version 1 must be rebuilt.

## Benchmarks

Three-run medians on a 4,096-chunk world (8,192 saves) with identical payloads
and save order. Full saves hold four 16 KiB subchunks, biomes, block entities
and entities; later saves mix full saves with two-component updates. A chunk
read is seven gets.

| Workload | ZigriteDB | PMMP LevelDB fork |
| --- | ---: | ---: |
| Buffered chunk saves | 15,033 saves/s | 434 saves/s |
| Synchronous chunk saves | 193 saves/s | 178 saves/s |
| Durable groups of 16 saves | 2,321 saves/s | 444 saves/s |
| Chunk read p50, no cache, cold | 42 µs | 653 µs |
| Chunk read p50, 8 MiB cache | 31 µs | 199 µs |
| Reopen and first read | 68 ms | 40 ms |
| Size after writes / after full compaction | 132 / 90 MB | 97 / 76 MB |
| Peak memory | 19 MiB | 110 MiB |

**Native code only.** This compares ZigriteDB's C API with the
[C++ LevelDB fork](https://github.com/pmmp/leveldb) used by
[PMMP's PHP extension](https://github.com/pmmp/php-leveldb). PHP calls, NBT
serialization and the world provider are excluded, so these are not PMMP server
numbers.

Both engines run with the same cache size and with checksum verification on
(ZigriteDB always verifies; LevelDB's default does not). LevelDB uses PMMP's
[raw zlib and 64 KiB block settings](https://github.com/pmmp/PocketMine-MP/blob/stable/src/world/format/io/leveldb/LevelDB.php),
which is why its files are smaller. Buffered saves exclude the final barrier;
groups sync after every 16 saves. Measured on a Ryzen 5 5500 under WSL2
(Linux 6.6, ext4) with Zig 0.16.0 ReleaseSafe and LevelDB built with CMake
Release.

LevelDB still wins on database size and reopen time. Cache, thread scaling,
ReleaseFast and 64-chunk results are in the
[detailed results](tests/bench/results/README.md); see the
[build script](tests/bench/build_pmmp_native.sh) and
[runner](tests/bench/run_pmmp_native.py) to reproduce them.

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
