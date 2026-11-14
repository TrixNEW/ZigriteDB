<p align="center">
  <img src="assets/zigritedb_smaller.png" alt="ZigriteDB" width="260">
</p>

<p align="center">
  Embedded Minecraft Bedrock world storage, written in Zig.
</p>

ZigriteDB is a region-based storage engine for [Quark](https://github.com/Bedrock-Phanatics/Quark), with lossless import and export of Bedrock LevelDB worlds.

- **Fast reads:** indexed chunk lookups and whole-chunk reads.
- **Efficient writes:** batched, append-only storage with concurrent region I/O.
- **Reliable storage:** checksummed records, crash recovery and compaction.

**Requirements:** Zig 0.17.0 · Linux  
**Compatibility:** C ABI 3 · Disk format 2

## Build

```sh
zig build -Doptimize=ReleaseSafe
```

Builds the native C library, static Zig library and `zigrite` CLI.

## CLI

```sh
zigrite import <bedrock-world> <world>
zigrite export <world> <bedrock-world>
zigrite compare <bedrock-db> <bedrock-db>
zigrite migrate <old-world> <new-world>
zigrite verify <world> [bedrock-world]
zigrite compact <world>
zigrite recover <region> <empty-directory>
```

Import and export preserve and verify Bedrock keys, values and world files without modifying the source. Back up important worlds before migration.

## API

### Zig

Add ZigriteDB to your `build.zig`:

```zig
exe.root_module.addImport("zigritedb", b.createModule(.{
    .root_source_file = b.path("vendor/zigritedb/src/root.zig"),
    .target = target,
    .optimize = optimize,
}));
```

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

    const key: db.Key = .{
        .dimension = 0, .chunk_x = 4, .chunk_z = 8,
        .component = .subchunk, .subchunk_y = -2,
    };
    _ = try world.write(.{ .entries = &.{
        .put(key, "subchunk bytes"),
        .put(.{ .dimension = 0, .chunk_x = 4, .chunk_z = 8, .component = .version }, "\x28"),
    } });

    var buffer: [4096]u8 = undefined;
    var records: [64]db.ChunkRecord = undefined;
    var result: db.ChunkResult = undefined;
    try world.getChunk(0, 4, 8, &buffer, &records, &result);
    try world.close();
}
```

### C

Link `libzigritedb_native` and include [`zigritedb.h`](include/zigritedb.h).

| Operation | API |
| --- | --- |
| Chunk I/O | `zg_get_chunk`, `zg_write_group` |
| Raw keys | `zg_aux_get`, `zg_aux_put`, `zg_aux_delete` |
| Persistence | `zg_flush`, `zg_close` |
| World tools | `zg_import`, `zg_export`, `zg_verify`, `zg_migrate` |

Writes are buffered by default; call `flush` or `close` to make them durable. `writeGroup` commits durably. Atomicity is per region, not world-wide. See [`zigritedb.h`](include/zigritedb.h) and the [disk format](docs/format.md).

## Benchmarks

**16k-chunk Bedrock world** · Ryzen 5 5500 · WSL2 · ReleaseSafe · median of 5 runs

| Metric | LevelDB (PMMP Fork) | ZigriteDB |
| --- | ---: | ---: |
| Import | 4,086 chunks/s | **32,719 chunks/s** |
| Reopen + first chunk | 61 ms | **6.4 ms** |
| Cold chunk load (p50) | 130 µs | **9.9 µs** |
| Mixed load + autosave (p99) | 924 µs | **132 µs** |
| Autosave barrier (p50) | **4.8 ms** | 15.8 ms |
| Full compaction | 3.5 s | **2.1 s** |
| Size after compaction | **14.6 MB** | 33.0 MB |

Native C API benchmarks, not end-to-end server measurements. [Full results and methodology](tests/bench/results/README.md).

## Tests

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build fuzz --fuzz=10000
```

See [native release checks](tests/native/README.md) and [CI](.github/workflows/ci.yml).

## License

[LICENSE](LICENSE)
