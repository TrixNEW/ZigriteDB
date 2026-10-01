# PMMP LevelDB comparison results

Raw JSON for every run is in this folder; the tables below are medians produced by
[`summarize_pmmp_native.py`](../summarize_pmmp_native.py). See
[`wsl-pmmp-native-environment.json`](wsl-pmmp-native-environment.json) for the full setup.

## How to read these numbers

- **Native code only.** ZigriteDB's C API against the
  [pmmp/leveldb](https://github.com/pmmp/leveldb) fork that PMMP's PHP extension links. PHP,
  NBT serialization and the world provider are not included, so this is not PMMP server
  throughput.
- **Same settings on both sides.** LevelDB uses PMMP's raw zlib and 64 KiB blocks, an explicit
  block cache of the listed size and `verify_checksums` on, because ZigriteDB always verifies
  record checksums. LevelDB's default is an implicit 8 MiB cache with checksums off.
- **Durability.** `buffered` excludes the final barrier; `sync` syncs every save; `group`
  syncs after every 16 saves.
- **Reads.** A chunk read is seven gets (four subchunks, biomes, block entities, entities).
  `cold` runs right after the page cache is dropped (WSL2's host may still cache the virtual
  disk); `hot` repeats the same random chunks. `getMany` is ZigriteDB only.
- **Size.** `db MB` is after the write phase with automatic compaction on; `compacted MB` is
  after an explicit full compaction. LevelDB's zlib compresses better than ZigriteDB's LZ4.
- **Noise.** WSL2 timing varies run to run. The ReleaseSafe matrix ran about 15-20% slower for
  both engines than the separate thread and ReleaseFast runs.

## Where each engine wins

- ZigriteDB: buffered and grouped saves, every read case, `getMany`, read scaling across
  threads, and memory.
- LevelDB: database size (zlib), and reopen time on the 4096-chunk world (it does not replay
  data on open).
- Sync saves are bound by one `fsync` per save on both engines.

## Remaining limits

- Commits carry a SHA-256 of their records, which is now the largest write and reopen cost.
  Removing it means a new format version.
- Each dirty region needs its own `fsync` at a save barrier. Flushes run concurrently, which
  ext4 batches well, but a world-wide WAL would need only one. That also means a format change
  plus background repacking into regions, and is not worth it until the simpler paths are
  exhausted on real servers.
- Writes to one region are serialized; different regions write in parallel.
- Reopen replays every segment. A persisted index is not justified yet: replay runs at about
  2 GB/s and automatic compaction keeps regions small.
- The hardware CRC32C path is chosen at compile time; build with `-Dcpu=x86_64_v2` or newer.

## ReleaseSafe, one thread

| chunks | cache MiB | threads | mode | engine | saves/s | write p50 us | write p99 us | cold read p50 us | hot read p50 us | hot reads/s | getMany p50 us | reopen ms | db MB | compacted MB | rss MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 64 | 0 | 1 | buffered | leveldb | 3,696.1 | 33.9 | 331.2 | 550.2 | 545.5 | 1,787.6 | - | 97.7 | 13.0 | 1.2 | 22.4 |
| 64 | 0 | 1 | buffered | zig | 12,547.2 | 25.1 | 112.5 | 32.4 | 31.8 | 25,859.8 | 26.6 | 20.7 | 11.2 | 1.4 | 13.8 |
| 64 | 0 | 1 | group | leveldb | 2,052.9 | 6,927.6 | 13,381.9 | 635.7 | 643.4 | 1,535.2 | - | 51.9 | 7.8 | 1.2 | 18.8 |
| 64 | 0 | 1 | group | zig | 2,342.2 | 6,048.3 | 29,072.8 | 39.9 | 33.7 | 26,413.5 | 22.8 | 21.2 | 11.2 | 1.4 | 13.8 |
| 64 | 0 | 1 | sync | leveldb | 190.0 | 5,018.0 | 10,398.0 | 514.2 | 514.3 | 1,899.8 | - | 55.1 | 6.0 | 1.2 | 17.0 |
| 64 | 0 | 1 | sync | zig | 192.2 | 5,016.2 | 7,921.8 | 36.5 | 41.0 | 25,004.4 | 30.8 | 19.6 | 11.2 | 1.4 | 13.8 |
| 64 | 8 | 1 | buffered | leveldb | 3,688.5 | 35.6 | 391.3 | 19.6 | 13.6 | 36,867.2 | - | 94.9 | 13.0 | 1.2 | 25.7 |
| 64 | 8 | 1 | buffered | zig | 12,287.2 | 24.3 | 143.0 | 5.6 | 5.2 | 176,567.2 | 3.8 | 20.9 | 11.2 | 1.4 | 14.5 |
| 64 | 8 | 1 | group | leveldb | 1,995.0 | 6,963.4 | 14,356.1 | 41.6 | 12.9 | 71,653.5 | - | 50.7 | 7.7 | 1.2 | 25.7 |
| 64 | 8 | 1 | group | zig | 2,348.5 | 6,013.7 | 28,237.7 | 5.3 | 5.8 | 156,711.0 | 5.2 | 20.6 | 11.2 | 1.4 | 14.7 |
| 64 | 8 | 1 | sync | leveldb | 190.7 | 5,074.3 | 9,344.8 | 19.3 | 14.7 | 27,340.8 | - | 55.1 | 6.0 | 1.2 | 21.4 |
| 64 | 8 | 1 | sync | zig | 191.5 | 5,045.5 | 7,322.6 | 5.6 | 5.2 | 173,279.8 | 4.5 | 21.9 | 11.2 | 1.4 | 13.9 |
| 4096 | 0 | 1 | buffered | leveldb | 433.5 | 130.4 | 1,600.3 | 652.6 | 776.8 | 1,249.0 | - | 40.1 | 96.7 | 75.9 | 109.5 |
| 4096 | 0 | 1 | buffered | zig | 15,032.5 | 54.5 | 162.0 | 42.1 | 40.1 | 24,453.3 | 33.5 | 67.5 | 131.6 | 90.0 | 19.0 |
| 4096 | 0 | 1 | group | leveldb | 443.9 | 8,830.7 | 622,157.5 | 696.5 | 729.9 | 1,284.5 | - | 91.4 | 101.4 | 75.9 | 105.3 |
| 4096 | 0 | 1 | group | zig | 2,320.5 | 6,306.3 | 10,657.5 | 36.6 | 32.6 | 25,862.7 | 25.4 | 62.3 | 131.6 | 90.0 | 19.2 |
| 4096 | 0 | 1 | sync | leveldb | 178.4 | 5,203.3 | 10,766.3 | 665.0 | 593.5 | 1,578.2 | - | 39.5 | 94.0 | 75.9 | 97.4 |
| 4096 | 0 | 1 | sync | zig | 193.4 | 5,058.3 | 7,553.3 | 45.3 | 31.8 | 26,925.4 | 27.1 | 67.3 | 131.6 | 90.0 | 17.5 |
| 4096 | 8 | 1 | buffered | leveldb | 486.9 | 114.2 | 1,534.8 | 240.0 | 199.1 | 4,531.8 | - | 38.7 | 96.6 | 75.9 | 125.1 |
| 4096 | 8 | 1 | buffered | zig | 15,808.1 | 53.9 | 141.6 | 35.0 | 30.6 | 28,638.1 | 24.5 | 63.0 | 131.6 | 90.0 | 26.5 |
| 4096 | 8 | 1 | group | leveldb | 445.3 | 8,835.2 | 629,645.6 | 279.4 | 196.0 | 4,756.8 | - | 89.1 | 102.2 | 75.9 | 122.6 |
| 4096 | 8 | 1 | group | zig | 2,328.1 | 6,277.9 | 12,016.0 | 39.8 | 35.1 | 24,349.4 | 28.6 | 64.8 | 131.6 | 90.0 | 26.9 |
| 4096 | 8 | 1 | sync | leveldb | 172.5 | 5,318.9 | 10,937.9 | 227.7 | 199.6 | 4,627.9 | - | 38.7 | 89.3 | 75.9 | 112.4 |
| 4096 | 8 | 1 | sync | zig | 195.9 | 4,979.4 | 6,923.6 | 36.8 | 29.8 | 31,347.6 | 25.1 | 65.1 | 131.6 | 90.0 | 25.0 |

## ReleaseFast, buffered

| chunks | cache MiB | threads | mode | engine | saves/s | write p50 us | write p99 us | cold read p50 us | hot read p50 us | hot reads/s | getMany p50 us | reopen ms | db MB | compacted MB | rss MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 64 | 0 | 1 | buffered | leveldb | 4,451.9 | 27.5 | 251.0 | 424.6 | 425.6 | 2,241.0 | - | 78.3 | 13.0 | 1.2 | 22.5 |
| 64 | 0 | 1 | buffered | zig | 16,276.8 | 16.1 | 78.0 | 25.2 | 25.2 | 35,773.1 | 20.5 | 16.8 | 11.2 | 1.4 | 13.6 |
| 64 | 8 | 1 | buffered | leveldb | 4,461.3 | 27.4 | 227.7 | 11.4 | 8.5 | 44,055.0 | - | 79.5 | 13.0 | 1.2 | 25.1 |
| 64 | 8 | 1 | buffered | zig | 16,475.4 | 15.9 | 75.7 | 3.1 | 3.2 | 281,648.0 | 2.0 | 16.4 | 11.2 | 1.4 | 13.6 |
| 4096 | 0 | 1 | buffered | leveldb | 546.4 | 100.7 | 1,352.3 | 503.7 | 509.0 | 1,900.1 | - | 33.0 | 101.0 | 75.9 | 105.1 |
| 4096 | 0 | 1 | buffered | zig | 20,714.8 | 44.1 | 90.0 | 27.7 | 26.6 | 34,379.9 | 22.4 | 50.4 | 131.6 | 90.0 | 18.5 |
| 4096 | 8 | 1 | buffered | leveldb | 549.8 | 101.1 | 1,335.8 | 211.5 | 171.3 | 5,787.7 | - | 32.8 | 101.0 | 75.9 | 125.4 |
| 4096 | 8 | 1 | buffered | zig | 21,634.7 | 43.0 | 87.8 | 29.5 | 27.8 | 33,436.6 | 22.3 | 51.7 | 131.6 | 90.0 | 25.9 |

## Thread scaling, 4096 chunks, no cache

| chunks | cache MiB | threads | mode | engine | saves/s | write p50 us | write p99 us | cold read p50 us | hot read p50 us | hot reads/s | getMany p50 us | reopen ms | db MB | compacted MB | rss MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 4096 | 0 | 1 | buffered | leveldb | 539.0 | 99.2 | 1,385.0 | 551.0 | 506.1 | 1,908.9 | - | 36.1 | 101.0 | 75.9 | 100.7 |
| 4096 | 0 | 1 | buffered | zig | 20,339.4 | 45.7 | 99.0 | 27.2 | 25.8 | 35,503.5 | 23.1 | 52.6 | 131.6 | 90.0 | 19.1 |
| 4096 | 0 | 4 | buffered | leveldb | 536.0 | 492.4 | 37,326.6 | 952.2 | 778.3 | 4,786.9 | - | 79.9 | 100.2 | 75.9 | 123.8 |
| 4096 | 0 | 4 | buffered | zig | 25,173.9 | 53.9 | 607.3 | 38.2 | 26.8 | 126,516.7 | 23.6 | 52.8 | 131.6 | 90.0 | 19.5 |
| 4096 | 0 | 16 | buffered | leveldb | 542.1 | 2,257.6 | 960,983.2 | 7,510.5 | 1,176.5 | 7,753.8 | - | 78.4 | 99.5 | 75.9 | 131.8 |
| 4096 | 0 | 16 | buffered | zig | 27,328.8 | 111.3 | 3,453.8 | 48.8 | 45.8 | 172,790.5 | 37.7 | 54.1 | 131.6 | 90.0 | 23.0 |

## Thread scaling, 64 chunks, 8 MiB cache

| chunks | cache MiB | threads | mode | engine | saves/s | write p50 us | write p99 us | cold read p50 us | hot read p50 us | hot reads/s | getMany p50 us | reopen ms | db MB | compacted MB | rss MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 64 | 8 | 1 | buffered | leveldb | 3,119.8 | 29.2 | 1,230.7 | 9.0 | 7.7 | 64,518.7 | - | 69.1 | 11.3 | 1.2 | 26.2 |
| 64 | 8 | 1 | buffered | zig | 24,294.3 | 17.1 | 87.5 | 3.3 | 3.3 | 263,335.2 | 2.5 | 20.2 | 22.9 | 1.4 | 14.6 |
| 64 | 8 | 4 | buffered | leveldb | 3,153.2 | 1,240.1 | 26,939.1 | 25.7 | 23.4 | 103,447.9 | - | 59.6 | 11.9 | 1.2 | 31.6 |
| 64 | 8 | 4 | buffered | zig | 22,812.1 | 42.6 | 1,100.6 | 4.9 | 4.8 | 628,982.1 | 3.2 | 27.0 | 9.9 | 1.4 | 15.2 |
| 64 | 8 | 16 | buffered | leveldb | 3,276.5 | 4,099.1 | 40,858.8 | 49.2 | 44.5 | 166,730.0 | - | 73.9 | 13.3 | 1.2 | 44.1 |
| 64 | 8 | 16 | buffered | zig | 30,181.8 | 58.7 | 3,469.1 | 7.2 | 7.0 | 803,149.7 | 4.5 | 16.8 | 21.0 | 1.4 | 18.8 |

