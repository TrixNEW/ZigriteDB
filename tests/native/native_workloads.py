"""Seeded C API restart and compaction checks against a reference map."""
import ctypes as c
import os
from pathlib import Path
import random
import signal
import sys
import tempfile

from native_faults import API, ChunkRecord, Key, Operation, ReadRequest, ReadResult, Region, Stats, SUBCHUNK, VERSION

def check(library, path):
    api = API(library)
    api.options.buffered = 1
    api.options.max_open_regions = 2
    api.options.max_segment_size = 8192
    api.options.batch_buffer_size = 4096
    api.options.compression_threshold = 128
    api.options.cache_bytes = 64 * 1024
    rng = random.Random(20260915)
    expected = {}
    handle = api.open(path)
    last_stats = Stats()

    def stats_snapshot():
        current = Stats()
        assert api.lib.zg_stats_get(handle, c.byref(current)) == 0
        return current

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
                operations.append(Operation(Key(0, x, 0, 0, VERSION), int(value is None),
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
            current = stats_snapshot()
            assert current.get_calls >= last_stats.get_calls
            assert current.writes >= last_stats.writes and current.writes > 0
            last_stats = current
            if batch % 100 == 0:
                verify()
                result = api.lib.zg_close(handle)
                handle = None
                assert result == 0
                handle = api.open(path)
                last_stats = Stats()
                verify()
        verify()
    finally:
        if handle is not None:
            assert api.lib.zg_close(handle) == 0
    print("600 seeded batches, deletes, restarts and compactions passed")

def check_damaged_files(library):
    api = API(library)
    segment = "0000000000000001-0000000000000001.segment"
    # Damage at the active tail looks torn.
    cases = (("MANIFEST", "missing", 8), (segment, "missing", 6),
             (segment, "truncated", 8), (segment, "corrupt", 8), ("MANIFEST", "corrupt", 6))
    for name, damage, expected_status in cases:
        with tempfile.TemporaryDirectory(prefix="zigritedb-damaged-") as path:
            handle = api.open(path)
            assert api.write(handle, 1, [b"saved"]) == 0
            assert api.lib.zg_close(handle) == 0
            # Without INDEX, open checks every frame.
            (Path(path) / "00000000-00000000-00000000.region" / "INDEX").unlink()
            source = Path(path) / "00000000-00000000-00000000.region" / name
            if damage == "missing":
                saved = source.with_suffix(".saved")
                source.rename(saved)
                source = saved
            else:
                data = bytearray(source.read_bytes())
                if damage == "truncated":
                    data.pop()
                else:
                    data[-1] ^= 1
                source.write_bytes(data)
            original = source.read_bytes()
            handle = api.open(path)
            try:
                assert api.read(handle, 0)[0] == expected_status, (name, damage)
                assert api.write(handle, 2, [b"replacement"]) == expected_status
                assert source.read_bytes() == original
            finally:
                assert api.lib.zg_close(handle) == 0
    print("Missing, truncated and corrupt files fail safely without overwriting data")


def check_lifecycle(library, path):
    api = API(library)
    api.options.max_open_regions = 2
    api.options.max_segment_size = 64 * 1024
    api.options.batch_buffer_size = 4096
    api.options.compression_threshold = 32
    api.options.cache_bytes = 16 * 1024
    api.options.compact_min_bytes = 1
    api.options.compact_live_percent = 75
    region_count, cycles = 16, 32
    keys = (Key * (region_count * 2))(*[
        Key(0, region * 32, 0, y, component)
        for region in range(region_count) for component, y in ((VERSION, 0), (SUBCHUNK, -1))
    ])
    expected = {}
    baseline_fds = None
    automatic_compactions = 0

    def verify(handle):
        count = c.c_size_t()
        regions = (Region * region_count)()
        assert api.lib.zg_list_regions(handle, regions, region_count, c.byref(count)) == 0
        assert [(r.dimension, r.x, r.z) for r in regions[:count.value]] == [(0, r, 0) for r in range(region_count)]
        for region in range(region_count):
            x = region * 32
            assert api.read(handle, x) == (0, expected[region][0])
            buffers = [c.create_string_buffer(2048) for _ in range(3)]
            requests = (ReadRequest * 3)(
                ReadRequest(keys[2 * region], c.cast(buffers[0], c.c_void_p), len(buffers[0])),
                ReadRequest(keys[2 * region + 1], c.cast(buffers[1], c.c_void_p), len(buffers[1])),
                ReadRequest(Key(0, x + 1, 0, 0, VERSION), c.cast(buffers[2], c.c_void_p), len(buffers[2])),
            )
            results = (ReadResult * 3)()
            assert api.lib.zg_get_many(handle, requests, results, len(requests)) == 0
            for i, value in enumerate(expected[region]):
                assert (results[i].status, results[i].required, buffers[i].raw[:results[i].required]) == (0, len(value), value)
            assert (results[2].status, results[2].required) == (1, 0)
            required = c.c_size_t()
            assert api.lib.zg_get_chunk(handle, 0, x, 0, None, 0, None, 0, c.byref(count), c.byref(required)) == 3
            assert count.value == 2 and required.value == sum(map(len, expected[region]))
            output, records = c.create_string_buffer(required.value), (ChunkRecord * count.value)()
            assert api.lib.zg_get_chunk(handle, 0, x, 0, output, len(output), records, len(records),
                                        c.byref(count), c.byref(required)) == 0
            found = {(r.component, r.y): output.raw[r.offset:r.offset + r.length] for r in records[:count.value]}
            assert found == {(VERSION, 0): expected[region][0], (SUBCHUNK, -1): expected[region][1]}

    for cycle in range(cycles):
        handle = api.open(path)
        try:
            for region in range(region_count):
                for revision in (0, 1):
                    values = [bytes([cycle, region, revision]) * 256,
                              b"" if cycle % 4 == 0 else bytes([region, cycle, revision]) * 128]
                    buffers = [c.create_string_buffer(value) for value in values]
                    operations = (Operation * 2)(*[
                        Operation(keys[2 * region + i], 0, c.cast(buffer, c.c_void_p), len(value))
                        for i, (buffer, value) in enumerate(zip(buffers, values))
                    ])
                    result = api.lib.zg_write(handle, 0, operations, len(operations))
                    assert result == 0, (cycle, region, revision, result)
                expected[region] = values
            assert api.lib.zg_prefetch(handle, keys, len(keys)) == 0
            assert api.lib.zg_flush(handle) == 0
            verify(handle)
            stats = Stats()
            assert api.lib.zg_stats_get(handle, c.byref(stats)) == 0
            automatic_compactions += stats.compactions
            assert api.lib.zg_compact_async(handle, 0, cycle % region_count, 0) == 0
            assert api.lib.zg_maintenance_wait(handle) == 0
            assert api.lib.zg_compact(handle, 0, (cycle + 1) % region_count, 0) == 0
            # Leave explicit work queued: close must drain it after dropping best-effort queues.
            assert api.lib.zg_prefetch(handle, keys, len(keys)) == 0
            assert api.lib.zg_compact_async(handle, 0, (cycle + 2) % region_count, 0) == 0
        finally:
            assert api.lib.zg_close(handle) == 0
        handle = api.open(path)
        try:
            verify(handle)
        finally:
            assert api.lib.zg_close(handle) == 0
        fds = len(os.listdir("/proc/self/fd"))
        if baseline_fds is None:
            baseline_fds = fds
        assert fds == baseline_fds, ("file descriptor leak", cycle, baseline_fds, fds)
    assert automatic_compactions > 0, "automatic compaction never ran"
    print(f"{cycles * 2} C API open/close cycles across {region_count} regions passed; FDs stayed at {baseline_fds}")

if __name__ == "__main__":
    signal.alarm(300)
    check_damaged_files(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="zigritedb-model-") as path:
        check(Path(sys.argv[1]).resolve(), Path(path))
    with tempfile.TemporaryDirectory(prefix="zigritedb-lifecycle-") as path:
        check_lifecycle(Path(sys.argv[1]).resolve(), Path(path))
