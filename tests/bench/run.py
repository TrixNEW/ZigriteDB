"""Run isolated synthetic workloads on the filesystem chosen with --directory."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path("zig-out/bin/native_bench"))
    parser.add_argument("--library", type=Path, default=Path("zig-out/lib"))
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--batches", type=int, default=2048)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.batches < 128 or args.batches > 1000000 or args.batches % 16 or args.repeats < 1:
        parser.error("use 128..1000000 batches in multiples of 16 and at least one repeat")
    env = dict(os.environ, LD_LIBRARY_PATH=str(args.library.resolve()))
    results = []
    for mode in ("sync", "group", "buffered"):
        for repeat in range(args.repeats):
            with tempfile.TemporaryDirectory(prefix="zigritedb-bench-", dir=args.directory) as path:
                run = subprocess.run([str(args.binary.resolve()), path, str(args.batches), mode],
                                     env=env, check=True, capture_output=True, text=True, timeout=600)
                result = json.loads(run.stdout)
                result["repeat"] = repeat
                result["database_bytes"] = sum(file.stat().st_size for file in Path(path).rglob("*") if file.is_file())
                results.append(result)
    print(json.dumps({"platform": platform.platform(), "synthetic": True,
                      "group_batches_per_call": 16, "results": results}, indent=2))


if __name__ == "__main__":
    main()
