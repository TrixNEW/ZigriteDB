"""Check the current world benchmark on both engines without timing thresholds."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--library", type=Path, action="append", default=[])
    args = parser.parse_args()
    runner = Path(__file__).with_name("run_world.py")
    with tempfile.TemporaryDirectory(prefix="zigritedb-bench-smoke-") as temporary:
        dataset = Path(temporary) / "smoke.zgds"
        with dataset.open("wb") as file:
            file.write(struct.pack("<4sI", b"ZGDS", 16))
            for x in (0, 1, 32, 33):
                for z in (0, 1, 32, 33):
                    file.write(struct.pack("<iiH", x, z, 3))
                    for tag, y, value in ((0x2c, 0, b"\x28"), (0x2f, -1, bytes(range(256)) * 4),
                                          (0x31, 0, b"entity")):
                        file.write(struct.pack("<BbI", tag, y, len(value)))
                        file.write(value)
        for engine, read in (("leveldb", "record"), ("zig", "record"), ("zig", "chunk")):
            command = [sys.executable, str(runner), "--binary", str(args.binary), "--dataset", str(dataset),
                       "--engine", engine, "--repeats", "1"]
            for library in args.library:
                command.extend(["--library", str(library)])
            command.extend(["ops=32", "threads=2", "cache=1", "regions=2", "verify=1", f"read={read}",
                            "phases=load,update,autosave,compact"])
            run = subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
            result = json.loads(run.stdout)
            assert (result["engine"], result["chunks"], result["records"]) == (engine, 16, 48)
            assert all(result[phase]["calls"] == 32 for phase in ("load_cold", "load_hot", "update"))
            assert result["autosave_barrier"]["calls"] == 16 and "compaction_ms" in result
            print(f"Benchmark import/reopen/read/update/flush/compaction passed: {engine}, {read}")


if __name__ == "__main__":
    main()
