import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile


def numbers(text):
    return [int(value) for value in text.split(",")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--leveldb-library", type=Path, required=True)
    parser.add_argument("--zig-library", type=Path, default=Path("zig-out/lib"))
    parser.add_argument("--directory", type=Path, default=Path("/tmp"))
    parser.add_argument("--saves", type=int, default=1024)
    parser.add_argument("--chunks", type=numbers, default=[64])
    parser.add_argument("--cache-mib", type=numbers, default=[0, 8])
    parser.add_argument("--threads", type=numbers, default=[1])
    parser.add_argument("--modes", default="buffered,sync,group")
    parser.add_argument("--verify", type=int, choices=(0, 1), default=1)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--zig-optimize", default="ReleaseSafe")
    args = parser.parse_args()
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = os.pathsep.join((str(args.zig_library.resolve()),
                                               str(args.leveldb_library.resolve()),
                                               env.get("LD_LIBRARY_PATH", "")))
    results = []
    for repeat in range(args.repeats):
        for chunks in args.chunks:
            saves = max(args.saves, chunks * 2)
            for cache in args.cache_mib:
                for threads in args.threads:
                    for mode in args.modes.split(","):
                        if mode == "group" and threads != 1:
                            continue
                        engines = ("zig", "leveldb") if repeat % 2 == 0 else ("leveldb", "zig")
                        for engine in engines:
                            with tempfile.TemporaryDirectory(prefix="zigritedb-pmmp-native-", dir=args.directory) as path:
                                command = [str(args.binary.resolve()), path, str(saves), engine, mode,
                                           str(chunks), str(cache), str(args.verify), str(threads)]
                                run = subprocess.run(command, env=env, check=True, capture_output=True, text=True, timeout=1800)
                                result = json.loads(run.stdout)
                                result["repeat"] = repeat
                                results.append(result)
    print(json.dumps({"platform": platform.platform(), "native_only": True, "php_included": False,
                      "zig_optimize": args.zig_optimize, "leveldb_build": "CMake Release (-O3), zlib raw, 64 KiB blocks",
                      "leveldb_fork": "pmmp/leveldb", "leveldb_ref": "1c7564468b41610da4f498430e795ca4de0931ff",
                      "extension_ref": "88071eb1b1eae96af043229104b9d813f7cbe40c",
                      "repeats": args.repeats, "results": results}, indent=2))


if __name__ == "__main__":
    main()
