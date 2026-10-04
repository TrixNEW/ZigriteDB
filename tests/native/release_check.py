"""Native model soak, full verification and conversion, optionally under Valgrind."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", type=Path, default=Path("zig-out/bin"))
    parser.add_argument("--directory", type=Path, default=Path(tempfile.gettempdir()))
    parser.add_argument("--duration", default="60s")
    parser.add_argument("--cycles", type=int)
    parser.add_argument("--ops", type=int, default=400)
    parser.add_argument("--seed", type=int, default=20261004)
    parser.add_argument("--leak-check", action="store_true")
    args = parser.parse_args()
    binaries = args.bin.resolve()
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = str(binaries.parent / "lib") + os.pathsep + env.get("LD_LIBRARY_PATH", "")
    checker = ["valgrind", "--leak-check=full", "--show-leak-kinds=all", "--errors-for-leak-kinds=all",
               "--error-exitcode=99", "--track-fds=yes"] if args.leak_check else []

    def run(binary, *arguments, expected=0):
        result = subprocess.run(checker + [str(binaries / binary)] + list(map(str, arguments)), env=env,
                                stderr=subprocess.PIPE if checker else None, text=True)
        if checker:
            print(result.stderr, end="", file=sys.stderr)
            descriptors = re.search(r"FILE DESCRIPTORS: (\d+) open \((\d+) std\)", result.stderr)
            assert descriptors and descriptors[1] == descriptors[2], (binary, "open non-standard descriptors")
        assert result.returncode == expected, (binary, arguments, result.returncode)

    with tempfile.TemporaryDirectory(prefix="zigritedb-release-", dir=args.directory) as temporary:
        root = Path(temporary)
        smoke, soak = root / "smoke", root / "soak"
        smoke.mkdir()
        soak.mkdir()
        run("native_smoke", smoke)
        limits = ["--cycles", args.cycles] if args.cycles is not None else ["--duration", args.duration]
        run("native_soak", soak, *limits, "--ops", args.ops, "--seed", args.seed)
        run("zigrite", "verify", soak / "world")
        run("zigrite", "verify", soak / "recovered")
        run("zigrite", "export", soak / "world", root / "bedrock")
        run("zigrite", "import", root / "bedrock", root / "imported")
        run("zigrite", "verify", root / "imported")
        run("zigrite", "export", root / "imported", root / "roundtrip")
        run("zigrite", "compare", root / "bedrock/db", root / "roundtrip/db")
        run("zigrite", "import", root / "bedrock", root / "imported", expected=1)
        run("zigrite", "export", root / "missing", root / "invalid", expected=1)
    print("Native release checks passed" + (" under Valgrind" if args.leak_check else ""))


if __name__ == "__main__":
    main()
