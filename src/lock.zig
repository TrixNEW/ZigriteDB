const std = @import("std");

// std.Io.Mutex sleeps as soon as it is contended; ours are held for well under a microsecond.
const spins = 100;

pub fn lock(mutex: *std.Io.Mutex, io: std.Io) std.Io.Cancelable!void {
    if (spin(mutex)) return;
    try mutex.lock(io);
}

pub fn lockUncancelable(mutex: *std.Io.Mutex, io: std.Io) void {
    if (spin(mutex)) return;
    mutex.lockUncancelable(io);
}

fn spin(mutex: *std.Io.Mutex) bool {
    for (0..spins) |_| {
        if (mutex.tryLock()) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}
