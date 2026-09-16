"""Seeded C API restart and compaction checks against a reference map."""
import ctypes as c
from pathlib import Path
import random
import sys
import tempfile

from native_faults import API, Key, Operation


def check(library, path):
    api = API(library)
    api.options.buffered = 1
    api.options.max_open_shards = 2
    api.options.max_segment_size = 8192
    api.options.batch_buffer_size = 4096
    api.options.compression_threshold = 128
    rng = random.Random(20260915)
    expected = {}
    handle = api.open(path)

    def verify():
        for x in range(96):
            result = api.read(handle, x)
            if x in expected:
                assert result == (0, expected[x]), (x, result, expected[x])
            else:
                assert result == (1, b""), (x, result)

    try:
        for batch in range(1, 601):
            region = rng.randrange(3)
            operations, buffers, changes = [], [], []
            for _ in range(rng.randrange(1, 5)):
                x = region * 32 + rng.randrange(32)
                value = None if rng.randrange(5) == 0 else rng.choice(
                    [b"", rng.randbytes(40), bytes([batch % 256]) * 512])
                buffer = c.create_string_buffer(value or b"")
                buffers.append(buffer)
                operations.append(Operation(Key(0, x, 0, 0, 5), int(value is None),
                                            c.cast(buffer, c.c_void_p), len(value or b"")))
                changes.append((x, value))
            array = (Operation * len(operations))(*operations)
            assert api.lib.zg_write(handle, batch, array, len(array)) == 0
            for x, value in changes:
                if value is None:
                    expected.pop(x, None)
                else:
                    expected[x] = value
            if batch % 37 == 0:
                assert api.lib.zg_compact_async(handle, 0, region, 0) == 0
                assert api.lib.zg_maintenance_wait(handle) == 0
            if batch % 100 == 0:
                verify()
                result = api.lib.zg_close(handle)
                handle = None
                assert result == 0
                handle = api.open(path)
                verify()
        verify()
    finally:
        if handle is not None:
            assert api.lib.zg_close(handle) == 0
    print("600 seeded batches, deletes, restarts and compactions passed")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="zigritedb-model-") as path:
        check(Path(sys.argv[1]).resolve(), Path(path))
