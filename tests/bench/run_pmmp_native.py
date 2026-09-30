import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--leveldb-library", type=Path, required=True)
    parser.add_argument("--zig-library", type=Path, default=Path("zig-out/lib"))
    parser.add_argument("--directory", type=Path, default=Path("/tmp"))
    parser.add_argument("--saves", type=int, default=1024)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.saves < 64 or args.saves % 16 or args.repeats < 1:
        parser.error("use at least 64 saves in multiples of 16 and at least one repeat")
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = os.pathsep.join((str(args.zig_library.resolve()),
                                               str(args.leveldb_library.resolve()),
                                               env.get("LD_LIBRARY_PATH", "")))
    results = []
    for repeat in range(args.repeats):
        for mode in ("buffered", "sync", "group"):
            engines = ("zig", "leveldb") if repeat % 2 == 0 else ("leveldb", "zig")
            for engine in engines:
                with tempfile.TemporaryDirectory(prefix="zigritedb-pmmp-native-", dir=args.directory) as path:
                    run = subprocess.run([str(args.binary.resolve()), path, str(args.saves), engine, mode],
                                         env=env, check=True, capture_output=True, text=True, timeout=600)
                    result = json.loads(run.stdout)
                    result["repeat"] = repeat
                    result["database_bytes"] = sum(file.stat().st_size for file in Path(path).rglob("*") if file.is_file())
                    results.append(result)
    print(json.dumps({"platform": platform.platform(), "native_only": True, "php_included": False,
                      "leveldb_fork": "pmmp/leveldb", "leveldb_ref": "1c7564468b41610da4f498430e795ca4de0931ff",
                      "extension_ref": "88071eb1b1eae96af043229104b9d813f7cbe40c",
                      "saves": args.saves, "repeats": args.repeats, "results": results}, indent=2))


if __name__ == "__main__":
    main()
