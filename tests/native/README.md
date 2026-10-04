# Native release checks

Run on Linux with Zig 0.16.0, a C compiler and Python 3. Build the C API drivers
and conversion tool, then run the model workload:

```sh
zig build native-test native-soak
zig build
python3 tests/native/release_check.py --duration 30m
```

`--duration` accepts seconds, minutes or hours (for example `2h`). `--seed`
reproduces each worker's operation sequence; thread scheduling still varies.
`--cycles 2 --ops 32` bounds the workload for the slower leak checker.
The model checks acknowledged writes during reads, flushes, compaction and region
eviction, then checks every value after close/reopen. FDs and threads must return
to their initial counts after every cycle. Partial-write failures are recovered
into a separate directory without changing the source. The runner also verifies
all frames and compares an import/export round trip.

Install Valgrind (`sudo apt-get install valgrind` on Ubuntu), then run:

```sh
python3 tests/native/release_check.py --leak-check --cycles 2 --ops 32
```

Memcheck checks the C allocator and conversion tools, fails on memory errors,
all reported leak kinds and non-standard descriptors left open. No suppressions are
used. Zig 0.16.0 does not expose a clean ASan/LSan build option for this project.
CI runs this bounded check and a short ReleaseFast soak; the full crash/fault,
ThreadSanitizer and parser fuzz checks remain in the existing workflow.

Before tagging v1, run these checks on a **native Linux machine and filesystem**,
with the checkout, temporary worlds and benchmark outputs on that filesystem.
Use `--directory /path/on/that/filesystem` if `/tmp` is elsewhere. Run the normal
CI checks and the long soak in Debug, ReleaseSafe and ReleaseFast:

```sh
zig build native-test native-soak -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
python3 tests/native/release_check.py --directory /path/to/scratch --duration 30m
```

Repeat with `-Doptimize=ReleaseFast`; keep a Debug build for Valgrind. Run the
[existing real-world benchmark commands](../bench/results/README.md#setup) on
the same native filesystem, including the mixed reader/writer phases and the
`--writers mode=sync cache=8` sweep. These cover import, reopen, cold/hot reads,
autosave/flush barriers and compaction. Compare repeated runs of the candidate
against the previous revision with the same datasets, options and build mode.
Only significant, reproducible regressions should block release; CI has no
latency thresholds. WSL2 results alone do not complete this native Linux gate.
