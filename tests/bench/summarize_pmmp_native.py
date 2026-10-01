import argparse
import json
from statistics import median


def main():
    parser = argparse.ArgumentParser(description="Median table from run_pmmp_native.py output")
    parser.add_argument("results", nargs="+")
    args = parser.parse_args()
    rows = {}
    for path in args.results:
        for result in json.load(open(path))["results"]:
            key = (result["chunks"], result["cache_mib"], result["threads"], result["mode"], result["engine"])
            rows.setdefault(key, []).append(result)

    columns = [
        ("saves/s", lambda r: r["logical_saves_per_second"]),
        ("write p50 us", lambda r: r["write_calls"]["p50_us"]),
        ("write p99 us", lambda r: r["write_calls"]["p99_us"]),
        ("cold read p50 us", lambda r: r["chunk_reads_cold"]["p50_us"]),
        ("hot read p50 us", lambda r: r["chunk_reads_hot"]["p50_us"]),
        ("hot reads/s", lambda r: r["chunk_reads_hot"]["calls_per_second"]),
        ("getMany p50 us", lambda r: r["chunk_reads_many"]["p50_us"] if "chunk_reads_many" in r else None),
        ("reopen ms", lambda r: r["cold_reopen_and_read_ms"]),
        ("db MB", lambda r: r["database_bytes"] / 1e6),
        ("compacted MB", lambda r: r["compacted_database_bytes"] / 1e6),
        ("rss MiB", lambda r: r["peak_rss_kib"] / 1024),
    ]
    print("| chunks | cache MiB | threads | mode | engine | " + " | ".join(name for name, _ in columns) + " |")
    print("|" + " --- |" * (5 + len(columns)))
    for key in sorted(rows):
        cells = []
        for _, pick in columns:
            values = [value for value in map(pick, rows[key]) if value is not None]
            cells.append(f"{median(values):,.1f}" if values else "-")
        print("| " + " | ".join(str(part) for part in key) + " | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
