import ctypes as c
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

from native_faults import API, Key, Operation, VERSION, SUBCHUNK, trace


def tree_hash(path):
    digest = hashlib.sha256()
    for file in sorted(p for p in path.rglob("*") if p.is_file()):
        digest.update(str(file.relative_to(path)).encode())
        digest.update(file.read_bytes())
    return digest.hexdigest()


def build_source(library, zigrite, root):
    api = API(library)
    api.options.max_segment_size = 1 << 20
    api.options.batch_buffer_size = 1 << 16
    world = root / "zigrite-source"
    world.mkdir()
    handle = api.open(world)
    buffers = []
    for x in range(-40, 40, 3):
        values = [bytes([x & 0xff]) * 900, b"v", bytes(range(256)) * 5]
        keys = [Key(0, x, -x, -2, SUBCHUNK), Key(0, x, -x, 0, VERSION), Key(1, x, x, 4, SUBCHUNK)]
        for key, value in zip(keys, values):
            buffer = c.create_string_buffer(value)
            buffers.append(buffer)
            operation = Operation(key, 0, c.cast(buffer, c.c_void_p), len(value))
            assert api.lib.zg_write(handle, 0, c.byref(operation), 1) == 0
    for i in range(40):
        name = f"player_{i}".encode()
        assert api.lib.zg_aux_put(handle, name, len(name), name * 30, len(name) * 30) == 0
    assert api.lib.zg_close(handle) == 0
    (world / "bedrock").mkdir()
    (world / "bedrock" / "level.dat").write_bytes(b"level")
    subprocess.run([zigrite, "export", str(world), str(root / "bedrock")], check=True, capture_output=True)
    return root / "bedrock"


def run(zigrite, args):
    def work(_api, _path, _ack):
        os.execv(zigrite, [zigrite] + args)
    return work


def same_keys(zigrite, a, b):
    return subprocess.run([zigrite, "compare", str(a), str(b)], capture_output=True).returncode == 0


def check(zigrite, library, root, command, source, reference, stride):
    api = API(library)
    before = tree_hash(source)
    events, _ = trace(api, root, work=run(zigrite, [command, str(source), str(root / "probe")]))
    shutil.rmtree(root / "probe")
    cases = 0
    for mode in ("kill", "enospc", "eio"):
        step = stride if mode == "kill" else stride * 5
        for point in range(1, len(events) + 1, step):
            target = root / f"{command}-{mode}-{point}"
            trace(api, root, point, mode, work=run(zigrite, [command, str(source), str(target)]), exact=False, exits=(0, 1))
            assert tree_hash(source) == before, ("source changed", mode, point)
            if target.exists():
                db = target / "db" if command == "export" else None
                if db is None:
                    db = root / f"check-{mode}-{point}"
                    subprocess.run([zigrite, "export", str(target), str(db)], check=True, capture_output=True)
                    db = db / "db"
                assert same_keys(zigrite, reference, db), ("published a partial world", mode, point)
            shutil.rmtree(target, ignore_errors=True)
            subprocess.run([zigrite, command, str(source), str(target)], check=True, capture_output=True)
            shutil.rmtree(target)
            cases += 1
    print(f"{cases} {command} crash and I/O fault cases passed over {len(events)} syscalls")


def main():
    library, zigrite = Path(sys.argv[1]).resolve(), str(Path(sys.argv[2]).resolve())
    stride = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    signal.alarm(3600)
    with tempfile.TemporaryDirectory(prefix="zigritedb-convert-") as temporary:
        root = Path(temporary)
        bedrock = build_source(library, zigrite, root)
        check(zigrite, library, root, "import", bedrock, bedrock / "db", stride)
        subprocess.run([zigrite, "import", str(bedrock), str(root / "imported")], check=True, capture_output=True)
        check(zigrite, library, root, "export", root / "imported", bedrock / "db", stride)
    signal.alarm(0)


if __name__ == "__main__":
    main()
