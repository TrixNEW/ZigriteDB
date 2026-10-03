const std = @import("std");
const builtin = @import("builtin");

pub const transfer = @import("transfer.zig");

pub const File = struct {
    handle: std.Io.File,
    io: std.Io,

    pub fn readExact(self: File, buffer: []u8, offset: u64) !void {
        if (builtin.is_test) if (faults) |f| f.pauseRead();
        return transfer.readExact(self, buffer, offset);
    }

    pub fn writeAll(self: File, bytes: []const u8, offset: u64) !void {
        if (builtin.is_test) if (faults) |f| if (f.fail_write) {
            try transfer.writeAll(self, bytes[0 .. bytes.len / 2], offset);
            return error.NoSpaceLeft;
        };
        return transfer.writeAll(self, bytes, offset);
    }

    pub fn readSome(self: File, buffer: []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        return self.handle.readPositional(self.io, &.{buffer}, offset);
    }

    pub fn writeSome(self: File, bytes: []const u8, offset: u64) std.Io.File.WritePositionalError!usize {
        return self.handle.writePositional(self.io, &.{bytes}, offset);
    }

    /// Each call is capped at the readahead window, so it goes in steps.
    pub fn willNeed(self: File, len: u64) void {
        if (builtin.os.tag != .linux) return;
        const step = 1024 * 1024;
        var offset: u64 = 0;
        while (offset < len) : (offset += step) {
            _ = std.os.linux.fadvise(self.handle.handle, @intCast(offset), step, std.os.linux.POSIX_FADV.WILLNEED);
        }
    }

    pub fn length(self: File) std.Io.File.LengthError!u64 {
        return self.handle.length(self.io);
    }

    pub fn sync(self: File) !void {
        if (builtin.is_test) if (faults) |f| if (f.fail_sync) return error.InputOutput;
        if (builtin.os.tag != .linux) return self.handle.sync(self.io);
        const linux = std.os.linux;
        while (true) {
            try self.io.checkCancel();
            switch (linux.errno(linux.fsync(self.handle.handle))) {
                .SUCCESS => return,
                .INTR => continue,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .DQUOT => return error.DiskQuota,
                .ROFS => return error.ReadOnlyFileSystem,
                .ACCES, .PERM => return error.AccessDenied,
                else => return error.SyncFailed,
            }
        }
    }
};

/// Test-only fault injection.
pub const Faults = struct {
    fail_write: bool = false,
    fail_sync: bool = false,
    armed: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    fn pauseRead(self: *Faults) void {
        if (!self.armed.swap(false, .acq_rel)) return;
        self.paused.store(true, .release);
        while (!self.released.load(.acquire)) std.Thread.yield() catch {};
    }

    pub fn waitPaused(self: *Faults) void {
        while (!self.paused.load(.acquire)) std.Thread.yield() catch {};
    }
};

pub var faults: if (builtin.is_test) ?*Faults else void = if (builtin.is_test) null else {};
