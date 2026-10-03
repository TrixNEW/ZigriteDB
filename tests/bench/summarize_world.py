"""Median tables for run_world.py output. Usage: summarize_world.py results.jsonl..."""
import json
import statistics
import sys
from collections import defaultdict


def get(result, path):
    value = result
    for part in path.split("."):
        if not isinstance(value, dict) or value.get(part) is None:
            return None
        value = value[part]
    return value


WORKLOAD = [
    ("import chunks/s", "import_chunks_per_second", 1),
    ("import p50 us", "import.p50_us", 1),
    ("import p99 us", "import.p99_us", 1),
    ("db MB", "database_bytes", 1e-6),
    ("reopen+load ms", "reopen_and_first_load_ms", 1),
    ("cold load p50 us", "load_cold.p50_us", 1),
    ("cold load p99 us", "load_cold.p99_us", 1),
    ("cold reads/load", "load_cold_io.read_syscalls_per_op", 1),
    ("hot load p50 us", "load_hot.p50_us", 1),
    ("hot load p99 us", "load_hot.p99_us", 1),
    ("walk p50 us", "walk.p50_us", 1),
    ("walk p99 us", "walk.p99_us", 1),
    ("walk max us", "walk.max_us", 1),
    ("spawn ms", "walk_spawn_ms", 1),
    ("update p50 us", "update.p50_us", 1),
    ("update p99 us", "update.p99_us", 1),
    ("autosave p50 ms", "autosave_barrier.p50_us", 1e-3),
    ("mixed load p50 us", "mixed_load.p50_us", 1),
    ("mixed load p99 us", "mixed_load.p99_us", 1),
    ("mixed loads/s", "mixed_load.calls_per_second", 1),
    ("mixed update p50 us", "mixed_update.p50_us", 1),
    ("mixed update p99 us", "mixed_update.p99_us", 1),
    ("mixed barrier p50 ms", "mixed_barrier.p50_us", 1e-3),
    ("updated MB", "updated_database_bytes", 1e-6),
    ("reopen after updates ms", "reopen_after_updates_ms", 1),
    ("compaction ms", "compaction_ms", 1),
    ("final MB", "final_database_bytes", 1e-6),
    ("rss MiB", "peak_rss_kib", 1 / 1024),
    ("cpu s", "cpu_seconds", 1),
]

WRITERS = [
    ("saves/s", "writer_saves_per_second", 1),
    ("p50 us", "writers.p50_us", 1),
    ("p99 us", "writers.p99_us", 1),
    ("fsyncs", "stats.fsync_count", 1),
]


def fmt(value):
    if value is None:
        return "-"
    return f"{value:,.0f}" if abs(value) >= 100 else f"{value:,.1f}" if abs(value) >= 10 else f"{value:,.2f}"


def median(results, path, scale):
    values = [get(r, path) for r in results]
    values = [v * scale for v in values if v is not None]
    return statistics.median(values) if values else None


def main():
    results = [json.loads(line) for name in sys.argv[1:] for line in open(name) if line.strip()]
    workload = defaultdict(list)
    writers = defaultdict(list)
    for r in results:
        key = (r["dataset"], r["label"], r["mode"])
        if r["phases"] == "writers":
            writers[key + (r["target"], r["threads"])].append(r)
        else:
            workload[key].append(r)
    for dataset in sorted({k[0] for k in workload}):
        columns = sorted(k for k in workload if k[0] == dataset)
        print(f"\n### {dataset} ({workload[columns[0]][0]['chunks']} chunks)\n")
        print("| metric | " + " | ".join(f"{k[1]} {k[2]}" for k in columns) + " |")
        print("| --- |" + " ---: |" * len(columns))
        for name, path, scale in WORKLOAD:
            print(f"| {name} | " + " | ".join(fmt(median(workload[k], path, scale)) for k in columns) + " |")
    if writers:
        print("\n### Writers\n")
        print("| dataset | engine | mode | target | threads | " + " | ".join(n for n, _, _ in WRITERS) + " |")
        print("| --- | --- | --- | --- | ---: |" + " ---: |" * len(WRITERS))
        for key in sorted(writers, key=lambda k: (k[0], k[1], k[2], k[3], k[4])):
            print("| " + " | ".join(str(p) for p in key) + " | " +
                  " | ".join(fmt(median(writers[key], p, s)) for _, p, s in WRITERS) + " |")


if __name__ == "__main__":
    main()
