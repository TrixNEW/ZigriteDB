<p align="center">
  <img src="assets/zigritedb_smaller.png" alt="ZigriteDB" width="260">
</p>

<p align="center">
  Embedded world storage built for fast chunk saves and reads.
</p>

ZigriteDB is an embedded Minecraft Bedrock world storage engine written in Zig
for [Quark](https://github.com/Bedrock-Phanatics/Quark). It imports and exports
Bedrock LevelDB worlds byte for byte.

> **In development:** The API may still change. Keep backups of worlds you care about.

## How it works

A world is split into 32×32 chunk regions. Each region is its own directory of
append-only segments, written as checksummed frames, with a small manifest naming
the live segments. A frame is one atomic batch; a record inside it is one Bedrock
chunk record (subchunk, biomes, block entities, ...) keyed by its chunk slot, tag
and Y.

- **Writes** batch per region and share fsyncs between concurrent writers.
  Different regions write and flush in parallel.
- **Reads** go through a dense in-memory index per region: one lookup finds every
  record of a chunk. `getChunk` reads a whole chunk in one call.
- **Every byte is checked.** Records carry a CRC-32C (hardware accelerated when
  the CPU has it, picked at runtime), frames bind their records together, and
  anything that doesn't verify is refused rather than skipped.
- **Reopen** loads an index checkpoint written on clean close. If it's missing or
  doesn't match, the region is replayed from its segments, which are always the
  source of truth.
- **Compaction** rewrites a region in the background in chunk order once enough
  of it is stale. Reads and writes carry on meanwhile.
- **Everything else** in a Bedrock world (players, maps, scoreboards, unknown
  keys) is stored as raw byte keys next to the chunks.

The on-disk layout is described in [docs/format.md](docs/format.md).

## Build

Requires **Zig 0.16.0** and **Linux** for storage operations.

```sh
zig build -Doptimize=ReleaseSafe
```

This builds `libzigritedb_native` (C API), a static Zig library and the `zigrite` tool.

## Converting worlds

```sh
zigrite import <bedrock world> <new world>   # LevelDB world -> ZigriteDB
zigrite export <world> <new bedrock world>   # ZigriteDB -> standalone LevelDB world
zigrite compare <bedrock db> <bedrock db>    # check two LevelDB dbs hold the same keys
zigrite migrate <old world> <new world>      # format 1 -> format 2
zigrite verify <world>                       # check every frame
zigrite compact <world>                      # compact every region
```

Import never modifies the source, and every command that creates a world builds it
under a temporary name and only renames it into place once it is complete and
synced. A round trip reproduces every LevelDB key and value exactly; `level.dat`
and the other world files are carried along. Exported worlds open in Bedrock and
PMMP without ZigriteDB.

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

Save and read a chunk:

```zig
const std = @import("std");
const db = @import("zigritedb");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, "world", .{});
    defer dir.close(io);
    var world = try db.World.open(allocator, io, dir, .{});
    defer world.deinit();

    const key: db.Key = .{ .dimension = 0, .chunk_x = 4, .chunk_z = 8, .component = .subchunk, .subchunk_y = -2 };
    _ = try world.write(.{ .entries = &.{
        .put(key, "subchunk bytes"),
        .put(.{ .dimension = 0, .chunk_x = 4, .chunk_z = 8, .component = .version }, "\x28"),
    } });

    var buffer: [4096]u8 = undefined;
    var records: [64]db.ChunkRecord = undefined;
    var result: db.ChunkResult = undefined;
    try world.getChunk(0, 4, 8, &buffer, &records, &result);
    for (records[0..result.count]) |record| std.debug.print("{} {d}\n", .{ record.component, record.value.len });

    try world.close();
}
```

A batch is atomic and stays within one region. `writeGroup` commits up to 64 batches
of one region and returns once they are durable. Writes are buffered by default:
`flush` makes completed writes durable across regions and is the save barrier;
`close` does the same at shutdown. Crash atomicity remains per region. Set
`.region = .{ .durability = .sync }` to sync every write.
`deinit` only frees memory. Raw Bedrock keys go through `db.aux.get`/`db.aux.put`. See
[World](src/world/world.zig) for the rest.

Compaction runs when you call `compact`, or set `World.compactor` to schedule it
yourself. The C API schedules it automatically.

## C API

Link `libzigritedb_native` and include [zigritedb.h](include/zigritedb.h). Both
install to `zig-out/lib` and `zig-out/include`.

The ABI is version 3. Compared to version 2:

- Components are Bedrock record tags (`ZG_SUBCHUNK = 0x2f`, ...); any tag is accepted.
- `zg_get_chunk` reads a whole chunk; `zg_aux_get`/`zg_aux_put`/`zg_aux_delete`
  handle raw Bedrock keys.
- `zg_options` gained `compact_min_bytes` and `compact_live_percent` (0 turns
  automatic compaction off). `zg_options_init` fills in the defaults.
- A batch ID of 0 takes the region's next ID.
- Format 1 worlds fail to open with `ZG_NEEDS_MIGRATION`; run `zigrite migrate`.

Version 2 clients must be rebuilt.

Calls on one handle may run concurrently with separate caller-owned buffers.
Wait for all calls to return before `zg_close`, which consumes the handle even on
error. Initialize options with `zg_options_init`; `max_open_regions` bounds the
region cache without changing the ABI 3 struct layout.

## Durability

| Mode | Acknowledged after |
| --- | --- |
| Buffered write (default) | in memory; durable after the next `flush` or `close` |
| Sync write | fsync |
| `writeGroup` / `zg_write_group` | fsync, once for the whole group |
| `flush` / `zg_flush` | fsync of every dirty region, run concurrently |

Concurrent writers to a region share one fsync. A failed write, fsync or manifest
update stops that region's writer instead of guessing what reached the disk. A torn
tail after a crash is detected on open, and `zg_recover_region` copies every
verified frame into a new directory.

Atomicity is per batch, and so per region. A crash during `flush` can leave some
regions saved and others not. A world-wide log would close that gap but writes every
byte twice, and measured fsync costs didn't justify it (see the benchmark notes).

## Benchmarks

Real Bedrock worlds replayed through ZigriteDB's C API and the
[LevelDB fork](https://github.com/pmmp/leveldb) PMMP uses, with PMMP's compression and
block size, an 8 MiB cache and checksums verified on both. Medians of 5 runs on WSL2,
Ryzen 5 5500, ReleaseSafe. **Native code only:** no PHP, NBT or server is involved.

| Rave (2.8k chunks) / Zhyrr (16k chunks) | LevelDB | ZigriteDB |
| --- | ---: | ---: |
| Import | 670 / 4,242 chunks/s | 13,066 / 24,725 chunks/s |
| Reopen and first chunk | 89 / 64 ms | 11 / 8 ms |
| Chunk load p50, cold | 230 / 117 µs | 26 / 9 µs |
| Chunk load p99, 4 players + autosave | 1,254 / 1,007 µs | 79 / 41 µs |
| Chunk update p50 / p99 | 11.7 / 4.8, 1,182 / 24 µs | 2.9 / 3.7, 15 / 46 µs |
| Autosave barrier p50 | 4.8 / 4.8 ms | 9.0 / 18.1 ms |
| Full compaction | 3.2 / 3.5 s | 0.18 / 0.80 s |
| Size after compaction | 11.9 / 14.6 MB | 28.6 / 41.2 MB |

LevelDB wins on size (zlib vs LZ4) and on save barriers, where it syncs one log and
ZigriteDB syncs every dirty region. Setup, every phase, writer sweeps, the format 1
comparison and raw data are in [tests/bench/results](tests/bench/results/README.md).

## Limitations

- Linux only for storage. Other targets build but can't open worlds.
- Benchmarks so far are from WSL2, not native Linux or a PMMP server (ZigriteDB has
  no PHP binding yet).
- A region holds at most 255 segments of up to 4 GiB each.
- Files are bigger than LevelDB's, since LZ4 trades ratio for speed.
- Saves are atomic per region, not across regions (see Durability).

## Testing

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build fuzz --fuzz=10000
```

Native crash, fault and workload checks live in [tests/native](tests/native),
including multi-region flush faults and repeated C API lifecycle/FD checks.
See the [release checks](tests/native/README.md) for the concurrent model soak,
Valgrind heap/resource validation and native Linux release gate.
ReleaseFast runs native smoke, workloads and concurrency without repeating the
full fault matrix. Benchmark CI checks contents and tooling, without speed limits.
See [CI](.github/workflows/ci.yml) for the full set.

## License

See [LICENSE](LICENSE).
