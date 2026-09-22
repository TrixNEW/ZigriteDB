"""Linux x86-64 C ABI and syscall-boundary crash tests; all data lives in temporary directories."""
from concurrent.futures import ThreadPoolExecutor
import threading
import ctypes as c
import errno
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile


class Options(c.Structure):
    _fields_ = [(name, c.c_uint32) for name in (
        "version", "struct_size", "max_open_shards", "max_keys", "max_segments", "batch_buffer_size"
    )] + [("max_segment_size", c.c_uint64), ("buffered", c.c_uint32), ("compression_threshold", c.c_uint32),
          ("cache_bytes", c.c_uint64), ("cache_shards", c.c_uint32), ("reserved", c.c_uint32)]


class Key(c.Structure):
    _fields_ = [(name, c.c_int32) for name in ("dimension", "x", "z", "y")] + [("component", c.c_uint32)]


class Operation(c.Structure):
    _fields_ = [("key", Key), ("remove", c.c_uint32), ("value", c.c_void_p), ("length", c.c_size_t)]


class Batch(c.Structure):
    _fields_ = [("id", c.c_uint64), ("operations", c.POINTER(Operation)), ("count", c.c_size_t)]


class Stats(c.Structure):
    _fields_ = [(name, c.c_uint64) for name in (
        "get_calls", "writes", "records_written", "raw_bytes_written", "compressed_bytes_written",
        "disk_reads", "bytes_read", "fsync_count", "fsync_duration_ns", "segment_rotations",
        "compactions", "compaction_input_bytes", "compaction_output_bytes", "compaction_duration_ns",
        "recovery_attempts", "recovery_errors", "cache_hits", "cache_misses", "cache_evictions",
    )]


class API:
    def __init__(self, library):
        self.lib = c.CDLL(str(library))
        signatures = {
            "zg_options_init": [c.POINTER(Options)],
            "zg_open": [c.c_char_p, c.c_size_t, c.POINTER(Options), c.POINTER(c.c_void_p)],
            "zg_close": [c.c_void_p],
            "zg_write": [c.c_void_p, c.c_uint64, c.POINTER(Operation), c.c_size_t],
            "zg_get": [c.c_void_p, c.POINTER(Key), c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)],
            "zg_flush": [c.c_void_p],
            "zg_write_group": [c.c_void_p, c.POINTER(Batch), c.c_size_t],
            "zg_compact_async": [c.c_void_p, c.c_int32, c.c_int32, c.c_int32],
            "zg_maintenance_wait": [c.c_void_p],
            "zg_last_batch_id": [c.c_void_p, c.c_int32, c.c_int32, c.c_int32, c.POINTER(c.c_uint64)],
            "zg_compact": [c.c_void_p, c.c_int32, c.c_int32, c.c_int32],
            "zg_recover_region": [c.c_char_p, c.c_size_t, c.c_char_p, c.c_size_t, c.POINTER(Options)],
            "zg_stats_get": [c.c_void_p, c.POINTER(Stats)],
            "zg_stats_reset": [c.c_void_p],
        }
        for name, arguments in signatures.items():
            fn = getattr(self.lib, name)
            fn.argtypes, fn.restype = arguments, c.c_int
        self.grouped = False
        self.options = Options()
        assert self.lib.zg_options_init(c.byref(self.options)) == 0
        self.options.max_segment_size = 256
        self.options.batch_buffer_size = 1024
        self.options.compression_threshold = 0

    def open(self, path):
        name = os.fsencode(path)
        handle = c.c_void_p()
        status = self.lib.zg_open(name, len(name), c.byref(self.options), c.byref(handle))
        assert status == 0, ("open", status)
        return handle

    def write(self, handle, batch, values):
        buffers = [c.create_string_buffer(value) for value in values]
        operations = (Operation * len(values))(*[
            Operation(Key(0, i, 0, 0, 5), 0, c.cast(buf, c.c_void_p), len(value))
            for i, (buf, value) in enumerate(zip(buffers, values))
        ])
        return self.lib.zg_write(handle, batch, operations, len(operations))

    def write_group(self, handle):
        buffers = [c.create_string_buffer(value) for value in (b"new0", b"new1", b"next0", b"next1")]
        operations = (Operation * 4)(*[
            Operation(Key(0, i % 2, 0, 0, 5), 0, c.cast(buffer, c.c_void_p), len(buffer) - 1)
            for i, buffer in enumerate(buffers)
        ])
        batches = (Batch * 2)(
            Batch(2, c.cast(operations, c.POINTER(Operation)), 2),
            Batch(3, c.cast(c.byref(operations, 2 * c.sizeof(Operation)), c.POINTER(Operation)), 2),
        )
        return self.lib.zg_write_group(handle, batches, 2)

    def read(self, handle, index):
        key, length = Key(0, index, 0, 0, 5), c.c_size_t()
        status = self.lib.zg_get(handle, c.byref(key), None, 0, c.byref(length))
        if status != 3:
            return status, b""
        assert length.value <= 16 * 1024 * 1024
        output = c.create_string_buffer(length.value)
        status = self.lib.zg_get(handle, c.byref(key), output, len(output), c.byref(length))
        return status, output.raw[:length.value]


libc = c.CDLL(None, use_errno=True)
libc.ptrace.argtypes = [c.c_uint, c.c_uint, c.c_void_p, c.c_void_p]
libc.ptrace.restype = c.c_long
REGS = c.c_uint64 * 27
EVENTS = {18: "pwrite64", 296: "pwritev", 328: "pwritev2", 74: "fsync", 75: "fdatasync",
          82: "rename", 264: "renameat", 316: "renameat2", 87: "unlink", 263: "unlinkat"}


def ptrace(request, pid, data=None):
    result = libc.ptrace(request, pid, None, data)
    if result == -1:
        raise OSError(c.get_errno(), "ptrace")


def workload(api, path, ack):
    name = os.fsencode(path)
    handle = c.c_void_p()
    opened = api.lib.zg_open(name, len(name), c.byref(api.options), c.byref(handle))
    if opened in (7, 14, 15):
        assert not handle.value
        return
    assert opened == 0, opened
    result = api.write_group(handle) if api.grouped else api.write(handle, 2, [b"new0", b"new1"])
    if result == 0:
        os.write(ack, b"W")
        result = api.lib.zg_compact(handle, 0, 0, 0)
    assert result in (0, 7, 12, 14, 15), ("unexpected injected result", result)
    assert api.lib.zg_close(handle) in (0, 7, 14, 15)


def trace(api, path, target=0, mode="baseline"):
    ack_read, ack_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(ack_read)
        try:
            ptrace(0, 0)
            os.kill(os.getpid(), signal.SIGSTOP)
            workload(api, path, ack_write)
            os._exit(0)
        except BaseException:
            import traceback
            traceback.print_exc()
            os._exit(1)
    os.close(ack_write)
    events, entering, injecting = [], True, False
    try:
        _, state = os.waitpid(pid, 0)
        assert os.WIFSTOPPED(state)
        ptrace(0x4200, pid, c.c_void_p(1 | 0x100000))
        while True:
            ptrace(24, pid)
            _, state = os.waitpid(pid, 0)
            if os.WIFEXITED(state):
                assert os.WEXITSTATUS(state) == 0
                break
            if os.WIFSIGNALED(state):
                raise AssertionError(("unexpected termination", os.WTERMSIG(state)))
            stopped = os.WSTOPSIG(state)
            if stopped != signal.SIGTRAP | 0x80:
                assert stopped in (signal.SIGTRAP, signal.SIGSTOP), stopped
                continue
            registers = REGS()
            ptrace(12, pid, c.byref(registers))
            if entering and registers[15] in EVENTS:
                events.append(EVENTS[registers[15]])
                if len(events) == target:
                    if mode == "kill":
                        os.kill(pid, signal.SIGKILL)
                        os.waitpid(pid, 0)
                        break
                    registers[15] = (1 << 64) - 1
                    ptrace(13, pid, c.byref(registers))
                    injecting = True
            elif not entering and injecting:
                registers[10] = (1 << 64) - {"enospc": errno.ENOSPC, "eio": errno.EIO, "readonly": errno.EROFS}[mode]
                ptrace(13, pid, c.byref(registers))
                injecting = False
            entering = not entering
        assert not target or len(events) >= target, ("fault was not reached", target, events)
        return events, os.read(ack_read, 1) == b"W"
    except BaseException:
        try:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except ProcessLookupError:
            pass
        raise
    finally:
        os.close(ack_read)


REGION = "00000000-00000000-00000000.region"


def verify(api, path, recovered, acknowledged):
    handle = api.open(path)
    first = api.read(handle, 0)
    if first[0] == 8:
        assert api.lib.zg_close(handle) == 0
        target = recovered / REGION
        target.mkdir(parents=True)
        source_name, target_name = os.fsencode(path / REGION), os.fsencode(target)
        status = api.lib.zg_recover_region(source_name, len(source_name), target_name, len(target_name), c.byref(api.options))
        assert status == 0, ("recovery", status)
        handle = api.open(recovered)
        first = api.read(handle, 0)
    second = api.read(handle, 1)
    assert first[0] == second[0] == 0, (first, second)
    allowed = [(b"base0", b"base1"), (b"new0", b"new1")]
    if api.grouped:
        allowed.append((b"next0", b"next1"))
    assert (first[1], second[1]) in allowed, (first, second)
    if acknowledged:
        assert (first[1], second[1]) == allowed[-1]
    assert api.lib.zg_close(handle) == 0


def check_permissions(api, root):
    denied = root / "denied"
    denied.mkdir(mode=0)
    pid = os.fork()
    if pid == 0:
        if os.geteuid() == 0:
            os.setgid(65534)
            os.setuid(65534)
        name = os.fsencode(denied)
        handle = c.c_void_p()
        result = api.lib.zg_open(name, len(name), c.byref(api.options), c.byref(handle))
        os._exit(0 if result == 13 and not handle.value else 1)
    _, result = os.waitpid(pid, 0)
    denied.chmod(0o700)
    assert os.WIFEXITED(result) and os.WEXITSTATUS(result) == 0


def check_concurrency(library, root, shard_limit=16):
    api = API(library)
    api.options.max_segment_size = 1024 * 1024
    api.options.max_open_shards = shard_limit
    api.options.compression_threshold = 32
    # Small enough to exercise eviction.
    api.options.cache_bytes = 16 * 1024
    path = root / f"concurrent-{shard_limit}"
    path.mkdir()
    handle = api.open(path)
    start = threading.Barrier(4)

    def writer(x):
        start.wait()
        for batch in range(1, 101):
            value = b"x" * (16 if batch % 2 else 512)
            buffer = c.create_string_buffer(value)
            operation = Operation(Key(0, x, 0, 0, 5), 0, c.cast(buffer, c.c_void_p), len(value))
            assert api.lib.zg_write(handle, batch, c.byref(operation), 1) == 0

    def reader():
        start.wait()
        for _ in range(300):
            for x in (0, 32):
                key, required = Key(0, x, 0, 0, 5), c.c_size_t()
                output = c.create_string_buffer(128)
                result = api.lib.zg_get(handle, c.byref(key), output, len(output), c.byref(required))
                if result == 0:
                    assert required.value == 16 and output.raw[:16] == b"x" * 16
                elif result == 3:
                    assert required.value == 512
                else:
                    assert result == 1 and required.value == 0

    def maintenance():
        start.wait()
        for _ in range(10):
            assert api.lib.zg_flush(handle) == 0
            assert api.lib.zg_compact_async(handle, 0, 0, 0) in (0, 9)
        assert api.lib.zg_maintenance_wait(handle) in (0, 1)

    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(writer, 0), pool.submit(writer, 32),
                       pool.submit(reader), pool.submit(maintenance)]
            for future in futures:
                future.result()
        for x in (0, 32):
            assert api.read(handle, x) == (0, b"x" * 512)
            batch_id = c.c_uint64()
            assert api.lib.zg_last_batch_id(handle, 0, x // 32, 0, c.byref(batch_id)) == 0
            assert batch_id.value == 100
        assert api.lib.zg_compact_async(handle, 0, 1, 0) == 0
    finally:
        assert api.lib.zg_close(handle) == 0
    print(f"Concurrent C API reads, writes and maintenance passed with {shard_limit} cached shards")


def check_stats(library, root):
    api = API(library)
    path = root / "stats"
    path.mkdir()
    handle = api.open(path)
    try:
        assert api.write(handle, 1, [b"first", b"second"]) == 0
        assert api.read(handle, 0)[0] == 0
        # Same region as 0 and 1, but never written.
        assert api.read(handle, 5)[0] == 1
        assert api.lib.zg_compact(handle, 0, 0, 0) == 0

        stats = Stats()
        assert api.lib.zg_stats_get(handle, c.byref(stats)) == 0
        assert stats.get_calls == 3, stats.get_calls  # Two reads and one miss.
        assert stats.writes == 1, stats.writes
        assert stats.records_written >= stats.writes
        assert stats.raw_bytes_written == stats.compressed_bytes_written == len(b"first") + len(b"second")
        assert stats.disk_reads > 0 and stats.bytes_read > 0
        assert stats.fsync_count > 0
        assert stats.compactions == 1

        assert api.lib.zg_stats_get(None, c.byref(stats)) == 2
        assert api.lib.zg_stats_get(handle, None) == 2

        assert api.lib.zg_stats_reset(handle) == 0
        assert api.lib.zg_stats_get(handle, c.byref(stats)) == 0
        for name, _ in Stats._fields_:
            assert getattr(stats, name) == 0, name

        assert api.write(handle, 0, [b"next"]) == 0
        batch_id = c.c_uint64()
        assert api.lib.zg_last_batch_id(handle, 0, 0, 0, c.byref(batch_id)) == 0
        assert batch_id.value == 2, batch_id.value
        assert api.read(handle, 0) == (0, b"next")
    finally:
        assert api.lib.zg_close(handle) == 0
    print("Runtime stats counters moved and reset correctly")


def main():
    assert sys.platform == "linux" and platform.machine() == "x86_64"
    library, smoke = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    api = API(library)
    signal.alarm(240)
    with tempfile.TemporaryDirectory(prefix="zigritedb-native-") as temporary:
        root = Path(temporary)
        check_permissions(api, root)
        check_stats(library, root)
        c_root = root / "c-smoke"
        c_root.mkdir()
        env = dict(os.environ, LD_LIBRARY_PATH=str(library.parent))
        subprocess.run([str(smoke), str(c_root)], env=env, check=True, timeout=30)
        template = root / "template"
        template.mkdir()
        handle = api.open(template)
        assert api.write(handle, 1, [b"base0", b"base1"]) == 0
        assert api.lib.zg_close(handle) == 0
        for grouped in (False, True):
            api.grouped = grouped
            baseline = root / f"baseline-{grouped}"
            shutil.copytree(template, baseline)
            events, acknowledged = trace(api, baseline)
            assert any("write" in event for event in events)
            assert any("sync" in event for event in events)
            assert any("rename" in event for event in events)
            assert any("unlink" in event for event in events)
            verify(api, baseline, root / f"baseline-recovered-{grouped}", acknowledged)
            for mode in ("kill", "enospc", "eio", "readonly"):
                for point in range(1, len(events) + 1):
                    case = root / f"{grouped}-{mode}-{point}"
                    shutil.copytree(template, case)
                    _, acknowledged = trace(api, case, point, mode)
                    verify(api, case, root / f"recovered-{grouped}-{mode}-{point}", acknowledged)
            print(f"{len(events) * 4} syscall-boundary crash and I/O fault cases passed: {sorted(set(events))}")
        for shard_limit in (1, 2, 16):
            check_concurrency(library, root, shard_limit)
    signal.alarm(0)


if __name__ == "__main__":
    main()
