<p align="center">
  <img src="assets/zigritedb_smaller.png" alt="ZigriteDB" width="260">
</p>

<p align="center">
  Embedded world storage built for fast chunk saves and reads.
</p>

ZigriteDB is an embedded storage engine for Minecraft Bedrock worlds, written
in Zig and built for [Quark](https://github.com/Bedrock-Phanatics/Quark).
Append-only writes, batched saves, indexed reads, and LZ4 compression keep
storage focused on individual chunk components.

**In development.** The API and file format may change. Not yet recommended
for production worlds.

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
Writes are buffered by default. Call `flush` at each save barrier or `close`
at shutdown to make prior writes durable. Set `.shard.durability = .sync` for
synchronous writes; `deinit` only releases resources.
See [World](src/world/world.zig) for the full Zig API.

For other languages, link against `libzigritedb_native` and use
[zigritedb.h](include/zigritedb.h). Libraries and headers are installed under
`zig-out/lib` and `zig-out/include`.

The C ABI is versioned by `ZG_ABI_VERSION`, which must equal `zg_abi_version()`.
Since v0.3.0, the C ABI is 2: `zg_options` grew, so programs built against an ABI 1
header must be rebuilt. On Linux the soname is `libzigritedb_native.so.2`, so
ABI 1 binaries will not load it. `zg_open` rejects a mismatched
`version`/`struct_size` before reading the rest.

## Benchmarks

Three-run medians for a synthetic Bedrock-style workload: 64 chunks across four
regions, four 16 KiB subchunks plus biomes, entities, block entities, heightmap,
and metadata. Later saves mix full and two-component dirty updates.

| Workload | Throughput | p50 | p95 |
| --- | ---: | ---: | ---: |
| Buffered chunk saves | 2,457 saves/s | 148 µs | 487 µs |
| Synchronous chunk saves | 169 saves/s | 5.63 ms | 6.83 ms |
| Nine-component random reads, no cache | 12,132 reads/s | 77 µs | 106 µs |
| Nine-component random reads, 16 MiB cache | 26,858 reads/s | 10 µs | 221 µs |

AMD Ryzen 5 5500; WSL2 Linux 6.6, `/tmp` on ext4; Zig 0.16.0 ReleaseSafe,
library source at `06ab3d1` plus this benchmark change. Cache read rows use
the same synchronous write setup. The cache improves the median but has a
higher p95 on this workload. No PMMP result is included because PHP and its
LevelDB extension were unavailable. These are synthetic measurements, not a
server trace or a comparison with another database.

```sh
zig build bench -Doptimize=ReleaseSafe
python3 tests/bench/run.py --directory /path/to/benchmark/filesystem
```

The runner emits latency through p99.9, throughput, memory, bytes, fsync,
cache, compaction, and reopen measurements as JSON. Raw results are in
[tests/bench/results](tests/bench/results). Use `--skip-unchanged` to compare
that option with the default on the same workload.

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
