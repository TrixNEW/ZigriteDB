# 1.1.1 audit

This pass covered the region store, indexes, cache ownership, group commits,
flush and eviction, compaction, manifests, checkpoints, recovery, compression,
the C ABI, overlays, Bedrock conversion, migration, and validation tooling.
The baseline is `0d46a87`. Zig remains at 0.16.0, C ABI at 3, and disk format at 2.
The package version is 1.1.1 and the native library version is 3.1.1.

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

Storage remains atomic per region. Autosave still syncs each dirty region, and
LZ4 still uses more space than LevelDB's raw zlib. Region creation still needs
its existing publication barriers.

Validation runs on WSL2 and its Linux filesystem. Native Linux, real power-loss
testing, a live Quark/PMMP server, other architectures and an hours-long soak
remain unverified. Passing the tests does not prove memory safety or crash safety.

Worlds previously imported with chunk-shaped keys in the reserved auxiliary
dimension should be recreated from their untouched LevelDB source.
