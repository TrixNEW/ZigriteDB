# 1.2.0 audit

This pass covered the region store, indexes, cache ownership, group commits,
flush and eviction, compaction, manifests, checkpoints, recovery, compression,
the C ABI, overlays, Bedrock conversion, migration, and validation tooling.
The baseline is `0d46a87` (1.1.0). The package is 1.2.0, the native library 3.2.0,
the C ABI stays 3 and the disk format stays 2. Zig moves from 0.16.0 to 0.17.0.

## Zig 0.17

Fuzzing found a panic in Zig 0.16's inflate: a raw deflate block truncated inside its
dynamic header overflowed in `tossBitsShort`, so a damaged LevelDB world could crash a
safe import and was undefined behaviour in ReleaseFast. Zig 0.17 fixes it upstream, so
the project moved compilers instead of carrying a patched decoder. The input is a
regression test in `src/bedrock/leveldb.zig`; 200,000 fuzz runs passed afterwards
where 0.16 aborted near 19,000.

## Storage changes

- New regions are created without fsyncs and published by their first sync, flush,
  rotation, compaction or close. `PENDING` marks the window, and open finishes it from
  segment 1 after a crash, so a killed process keeps every write that reached the file.
  The first buffered write into a new region dropped from 23 ms to 0.56 ms under WSL2.
- Compaction re-encodes records with a hash-chain, lazy-matching LZ4 parser when the
  result is smaller and decodes back exactly. INDEX checkpoints (version 2) store their
  body as LZ4 blocks. Compacted worlds are 18-20% smaller. Imports compact once at the end.

## Correctness and resource fixes

- Unchanged-write filtering decides which records to keep before moving bytes.
  Mixed lengths and repeated keys previously caused an invalid-header panic.
- Closing a world preserves a borrowed cache. The old cleanup tried to free it
  through the world's allocator, including caches allocated on the caller's stack.
- Compaction packs base frames within the configured segment size. An existing
  output generation also leaves the active writer usable.
- Recovery retains segments once manifest publication starts. A failed final
  directory sync previously left a visible manifest naming deleted files.
- Growing scanners make progress from an empty buffer. Recovery validates its
  options before allocating or opening directories.
- Checkpoint entries reject short buffers and invalid component keys. Loading
  validates all chunk counts before sizing its temporary arrays.
- C chunk reads bound temporary allocations independently of caller capacity.
  Oversized auxiliary keys are rejected before hashing, and overlays validate
  batches and their buffer limit before allocating.
- LevelDB logs handle block padding without dropping subsequent records or
  underflowing at EOF. Corrupt checksums, fragment ordering, overflowing varints,
  invalid sequences and trailing batch data are refused.
- LevelDB files sort by user key and descending sequence, including binary keys
  that are prefixes of other keys. Table entries cannot consume restart trailers.
- Block decompression enforces its exact size limit. LevelDB writer setup,
  compressed output, parser scratch and migration buffers clean up on allocation
  failure.
- World markers and conversion inputs use the existing regular-file opener.
  Pipes and symlinks fail without blocking or silently omitting live log files.
- Migration bounds counts, IDs, segment sizes, record sizes and decompressed
  batch bytes before allocating. Invalid source files leave no destination.
- Chunk-shaped raw keys using the auxiliary dimension remain raw during
  import/export, preserving their original bytes.

Regressions reproduced the original filtering panic, invalid cache free,
small-segment compaction failure, recovery publication failure, reserved-key
export failure, log-padding loss and binary-prefix ordering error.

## Benchmark tooling

Mixed workloads count every operation rather than stopping at the latency
sample limit. Throughput, mean and maximum latency cover the full run.
Percentiles use bounded per-worker reservoir samples with a separate random
stream. The autosave sampler is bounded too. The harness supports 1–64 clients
and allocates buffers only for the configured workers.

The LZ4 microbenchmark only decodes values actually compressed into its buffer.
`zig build micro -Doptimize=ReleaseSafe -- reopen <empty-directory>` measures
256 checkpoint-backed opens and reports tracked peak/retained bytes and
allocation counts. Setup and its fsyncs are outside the timer.

## Remaining limits

Storage remains atomic per region. Autosave still syncs each dirty region, about
2-3x LevelDB's single log fsync. LZ4 per record is still about twice LevelDB's zlib
over 64 KiB blocks after compaction. A region's first sync carries its publication
fsyncs. Regions with `skip_unchanged` keep their write-time encoding through
compaction, since fingerprints hash stored bytes. The mixed benchmark phase is too
noisy under WSL2 to rank builds.

Validation runs on WSL2 and its Linux filesystem. Native Linux, real power-loss
testing, a live Quark/PMMP server, other architectures and an hours-long soak
remain unverified. Passing the tests does not prove memory safety or crash safety.

Worlds previously imported with chunk-shaped keys in the reserved auxiliary
dimension should be recreated from their untouched LevelDB source.
