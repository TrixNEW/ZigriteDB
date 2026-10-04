# Benchmark results

Raw output for every run is in this folder, one JSON object per run. Tables are
medians from [`summarize_world.py`](../summarize_world.py).

## Setup

- Ryzen 5 5500 (6 cores, 12 threads), 8 GB, **WSL2** (Linux 6.6.87, ext4 on a virtual
  disk). No native Linux machine was available, so fsync timings in particular are
  WSL's, not bare metal's.
- Zig 0.16.0 ReleaseSafe; gcc 13.3 `-O2` for the harness and
  [pmmp/leveldb](https://github.com/pmmp/leveldb) at `1c75644`, CMake Release.
- **Native code only.** [`world.c`](../world.c) drives ZigriteDB's C API and PMMP's
  LevelDB fork with the same records, keys and access order. PHP, NBT and the world
  provider are not included; ZigriteDB has no PHP binding, so a PMMP server run was not
  possible.
- LevelDB uses PMMP's settings: raw zlib, 64 KiB blocks. Both engines get the same cache
  (8 MiB, LevelDB's default, or 0) and both verify checksums on read; ZigriteDB always
  does, LevelDB only with `verify_checksums`.
- `v1` is ZigriteDB at `14e6ed2` (format 1, ABI 2) with the same harness mapped to its
  component enum, and its default of 16 open regions. `v2` is this branch.
- Datasets are the overworld chunk records of two real Bedrock worlds, extracted with
  [`dataset.c`](../dataset.c): **Rave** (2,771 chunks, 120 MB raw) and **Zhyrr**
  (16,384 chunks, 334 MB raw).
- 5 runs per row for workloads, 3 for writer sweeps.

Reproduce with [`build.sh`](../build.sh) and [`run_world.py`](../run_world.py), e.g.
`run_world.py --binary world --dataset zhyrr.zgds --repeats 5 cache=8`.

## Phases

| phase | what it does |
| --- | --- |
| import | write every chunk once, buffered, then one barrier |
| reopen+load | open the database and read one chunk |
| cold / hot load | read random chunks after dropping the page cache / again |
| walk | read chunks along a player's path, 8-chunk radius |
| spawn | read the 17×17 chunks around spawn |
| update | rewrite block entities and a subchunk of a random chunk |
| autosave | 64 dirty chunks, then a durable barrier; 16 rounds |
| mixed | 4 player threads for 10 s, 1 in 5 operations an update, a barrier every 250 ms |
| compaction | full compaction after the updates |

## Workloads, 8 MiB cache (files: `*-cache8.jsonl`)

| Rave / Zhyrr | LevelDB | v1 | v2 |
| --- | ---: | ---: | ---: |
| import chunks/s | 670 / 4,242 | 8,140 / 15,255 | 13,066 / 24,725 |
| reopen + first load | 89 / 64 ms | 37 / 12 ms | 11 / 8 ms |
| cold load p50 | 230 / 117 µs | 38 / 20 µs | 26 / 9 µs |
| cold load p99 | 780 / 846 µs | 472 / 12,917 µs | 241 / 1,573 µs |
| hot load p50 | 224 / 111 µs | 29 / 18 µs | 25 / 8 µs |
| walk p99 | 727 / 944 µs | 72 / 59 µs | 37 / 20 µs |
| spawn | 45 / 28 ms | 56 / 41 ms | 17 / 14 ms |
| update p50 | 11.7 / 4.8 µs | 3.9 / 16.0 µs | 2.9 / 3.7 µs |
| update p99 | 1,182 / 24 µs | 30 / 20,869 µs | 15 / 46 µs |
| autosave barrier p50 | 4.8 / 4.8 ms | 9.5 / 18.8 ms | 9.0 / 18.1 ms |
| mixed load p99 | 1,254 / 1,007 µs | 258 / 144 µs | 79 / 41 µs |
| mixed update p99 | 218 / 193 µs | 103 / 81 µs | 23 / 20 µs |
| compaction | 3,194 / 3,456 ms | 538 / 1,769 ms | 179 / 796 ms |
| size after compaction | 11.9 / 14.6 MB | 34.4 / 50.9 MB | 28.6 / 41.2 MB |
| peak RSS | 175 / 385 MiB | 180 / 436 MiB | 169 / 386 MiB |
| CPU time | 65 / 63 s | 42 / 51 s | 40 / 41 s |

Peak RSS includes the dataset the harness holds in memory (about 120 / 334 MB).
Mixed loads/s isn't in the table: the harness stops recording at 128k samples per
thread, which caps ZigriteDB's figure at ~51k. LevelDB stays under the cap at
10.6k / 14.4k.

With no cache (`*-cache0.jsonl`) LevelDB has to inflate a 64 KiB block per read: cold
load p50 rises to 2.1 / 1.3 ms and its mixed loads drop to 1.2k / 2.8k per second. ZigriteDB
barely changes (21 / 6 µs). `v2-chunk-cache8.jsonl` reads through `zg_get_chunk`
instead of one `zg_get` per record; it matches per-record reads within noise here.

### Where LevelDB wins

- **Size.** zlib packs 2.5-3× tighter than LZ4.
- **Save barriers.** A barrier is one log fsync for LevelDB and one fsync per dirty
  region for ZigriteDB, run concurrently: 9 / 18 ms vs 5 ms.
- **Sync writes to many regions.** Each region needs its own fsync, so 16 threads in
  16 regions manage 563 saves/s vs LevelDB's 1,045 (see Writers).
- **Update tail on Zhyrr:** p99 24 µs vs 46 µs.

## Open-region limit (`v2-regions*.jsonl`)

Zhyrr spans 25 regions. With at most 16 open, random updates kept evicting dirty
regions, and each eviction flushed and fsynced before the new region opened. The
default is now 64.

| open regions | update p50 | p95 | p99 | peak RSS |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 11.4 µs | 7,217 µs | 8,237 µs | 392 MiB |
| 32 | 3.5 µs | 12 µs | 1,122 µs | 377 MiB |
| 64 | 3.6 µs | 12 µs | 1,113 µs | 379 MiB |

The remaining p99 in this short run is the first open of each region. An open region
holds its index and one file descriptor per segment plus one for its directory, usually
two or three.

## Writers (`*-writers*.jsonl`, Rave)

Threads saving continuously to one chunk, one region, or one region each.

| saves/s, 1 / 16 threads | LevelDB | v1 | v2 |
| --- | ---: | ---: | ---: |
| buffered, same region | 901 / 8,848 | 157k / 80k | 142k / 109k |
| buffered, own region | 899 / 9,210 | 166k / 240k | 177k / 375k |
| sync, same region | 214 / 1,657 | 226 / 1,637 | 136 / 1,648 |
| sync, own region | 138 / 1,045 | 217 / 913 | 216 / 563 |

Buffered LevelDB is held at ~1 ms per save by its level-0 slowdown. Sync saves are
bound by fsync on every engine and vary a lot run to run under WSL; concurrent writers
to one region share an fsync, so the same-region rows scale. Writers in separate regions
each need their own fsync in ZigriteDB, where LevelDB shares one log.

## Why there is no write-ahead log

A world-wide log would turn a barrier's per-region fsyncs into one. Measured with
[`fsync_probe.c`](../fsync_probe.c) (`fsync-probe.txt`, 64 KiB per region, 5 runs):

| dirty regions | concurrent region fsyncs | one log fsync |
| ---: | ---: | ---: |
| 1 | 5.2-8.7 ms | 5.0-9.2 ms |
| 4 | 9.5-14.9 ms | 4.9-7.7 ms |
| 16 | 10.3-17.8 ms | 5.8-8.5 ms |
| 64 | 15.0-22.1 ms | 9.7-13.8 ms |

A log saves 5-10 ms per barrier, but every byte would be written twice and replayed
into regions in the background, and a single log serializes writers that are parallel
today. Barriers run at autosave or shutdown, not per tick, so this stays as is until a
real server shows barrier time mattering.

## Micro benchmarks (`micro.json`)

`zig build micro -Doptimize=ReleaseSafe`.

- CRC-32C: 11.7 GB/s with SSE4.2 vs 2.3 GB/s for the table fallback at 64 KiB; picked
  at runtime, so portable builds keep the fast path.
- Region index for 32,768 records: the dense per-chunk index takes 1.1 MB vs 4.0 MB for
  a hash map, and finds all records of a chunk in 0.7 ns vs 210 ns. A single-key lookup
  is slower (17.7 vs 9.2 ns), which reads don't notice next to I/O and checksums.
