"""Runs world_bench repeatedly and prints one JSON result per line."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--library", type=Path, action="append", default=[], help="LD_LIBRARY_PATH entries")
    parser.add_argument("--label", default="zig", help="stored with each result, e.g. v1 or v2")
    parser.add_argument("--engine", default="zig", choices=("zig", "leveldb"))
    parser.add_argument("--dataset", type=Path, action="append", required=True)
    parser.add_argument("--directory", type=Path, default=Path("/tmp"))
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--writers", action="store_true", help="run the writer contention sweep instead")
    parser.add_argument("--threads", default="1,2,4,8,16")
    parser.add_argument("--targets", default="chunk,region,regions")
    parser.add_argument("args", nargs="*", help="extra key=value arguments for world_bench")
    args = parser.parse_args()
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = os.pathsep.join([str(p.resolve()) for p in args.library] + [env.get("LD_LIBRARY_PATH", "")])

    runs = []
    for dataset in args.dataset:
        if args.writers:
            for target in args.targets.split(","):
                for threads in args.threads.split(","):
                    runs.append((dataset, ["phases=writers", f"target={target}", f"threads={threads}"]))
        else:
            runs.append((dataset, []))
    for repeat in range(args.repeats):
        for dataset, extra in runs:
            with tempfile.TemporaryDirectory(prefix="zigritedb-world-", dir=args.directory) as path:
                command = [str(args.binary.resolve()), path, args.engine, str(dataset.resolve())] + extra + args.args
                run = subprocess.run(command, env=env, check=True, capture_output=True, text=True, timeout=3600)
                result = json.loads(run.stdout)
                result.update(label=args.label, dataset=dataset.stem, repeat=repeat)
                print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
