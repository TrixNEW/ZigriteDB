<p align="center">
  <img src="assets/zigritedb_smaller.png" alt="ZigriteDB" width="260">
</p>

<p align="center">
  An embedded storage engine for Minecraft Bedrock world and chunk data, written in <a href="https://github.com/ziglang/zig">Zig</a> v0.16.0.
</p>

<p align="center">
  A component-based world storage backend for Quark <a href="https://discord.gg/Yv9qPRQNc3">(Discord)
</p>

> [!WARNING]
> **ZigriteDB is currently a work in progress and is not ready for production use.**

* This project was created primarily to experiment with an idea I had for improving Minecraft world and chunk storage.
* The API and on-disk format may change while the project is still in development.
* I can't guarantee that this project will be maintained long-term, so ⭐ stars are appreciated if you'd like to see continued development.
* ZigriteDB can be integrated into other languages through its [C ABI](https://gist.github.com/MangaD/506a0f3273724ef3af26b8c085accdcb).
* If you use or build upon this project, credit is appreciated. :)

## Requirements

* [Zig](https://ziglang.org/) 0.16.0

## Build

```sh
zig build
```

For an optimized release build:

```sh
zig build -Doptimize=ReleaseSafe
```

## Tests

Run the test suite:

```sh
zig build test
```

Run tests with safety checks enabled:

```sh
zig build test -Doptimize=ReleaseSafe
```

The Linux native library and C header are installed by `zig build`. See
`include/zigritedb.h` for handle ownership, batch rules, and durability modes.

Run the native API and process-failure tests on Linux x86-64:

```sh
zig build native-test
python3 tests/native_faults.py zig-out/lib/libzigritedb_native.so zig-out/bin/native_smoke
python3 tests/native_workloads.py zig-out/lib/libzigritedb_native.so
```

## Native integration

Storage currently supports Linux. Link against `libzigritedb_native` and include
`zigritedb.h`; no database server or separate storage library is needed.

- Open an existing world directory with `zg_open`.
- Store chunk components separately using `zg_write`. Batch IDs increase per region;
  `zg_last_batch_id` lets a caller resume after reopening.
- Use `zg_write_group` for up to 64 same-region save batches with one final sync.
  Each batch is atomic; the whole group is not atomic on failure.
- `zg_get` uses a caller-owned buffer and reports the required size.
- `zg_compact_async` queues background work. `zg_maintenance_wait` drains it and
  reports errors. Reads continue during rewriting; same-region writes wait.
- Finish caller operations before `zg_close`. Close drains maintenance and frees
  the handle even if it reports an error.

Normal writes use sync durability by default. Buffered writes can be lost after
a crash until a successful flush, eviction, or close. Save groups always sync
before returning success. A failed write may have reached disk; inspect the
returned status before retrying.

There are at most four reusable native write buffers and one background worker
per handle. The maintenance queue holds 16 regions. Shard and segment limits are
configured through `zg_options`. Cache misses still serialize while files open.

The future ZPHP binding should own the native handle, translate statuses, and
pass component bytes without changing their encoding. Quark still needs a world
provider and a defined component schema. Bedrock LevelDB import/export belongs
in a separate offline tool once that schema exists.

## Benchmarks and fuzzing

On Linux:

```sh
zig build bench -Doptimize=ReleaseSafe
python3 bench/run.py --directory /path/to/benchmark/filesystem
zig build fuzz --fuzz=10000
```

The benchmark creates temporary databases and prints JSON for save latency,
hot/random reads, reads during compaction, replay, CPU, peak memory, and database
size. Group samples represent 16 batches per call; buffered saves are not durable
until the final flush. These synthetic workloads are not a Bedrock LevelDB
comparison or a substitute for real server traces. Keep the filesystem, build
mode, workload, and durability settings consistent when comparing results.

## Related Projects

Other projects in the Bedrock-Phanatics ecosystem:

* [zig-protocol](https://github.com/Bedrock-Phanatics/zig-protocol) — A Minecraft Bedrock protocol library written in Zig.
* [Quark](https://github.com/Bedrock-Phanatics/Quark) — Minecraft Bedrock server software written in PHP and utilizing a Zig runtime. ZigriteDB was originally created for Quark.
* [zig-nbt](https://github.com/Bedrock-Phanatics/zig-nbt) — An NBT library for Minecraft Bedrock written in Zig.

Feel free to ⭐ any of the projects if you find them useful.

## License

See [LICENSE](LICENSE).
