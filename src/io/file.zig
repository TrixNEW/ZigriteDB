const std = @import("std");

pub const transfer = @import("transfer.zig");

pub const File = struct {
    handle: std.Io.File,
    io: std.Io,

    pub fn readExact(self: File, buffer: []u8, offset: u64) !void {
        return transfer.readExact(self, buffer, offset);
    }

    pub fn writeAll(self: File, bytes: []const u8, offset: u64) !void {
        return transfer.writeAll(self, bytes, offset);
    }

    pub fn readSome(self: File, buffer: []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        return self.handle.readPositional(self.io, &.{buffer}, offset);
    }

    pub fn writeSome(self: File, bytes: []const u8, offset: u64) std.Io.File.WritePositionalError!usize {
        return self.handle.writePositional(self.io, &.{bytes}, offset);
    }

    pub fn length(self: File) std.Io.File.LengthError!u64 {
        return self.handle.length(self.io);
    }

    pub fn sync(self: File) !void {
        if (@import("builtin").os.tag != .linux) return self.handle.sync(self.io);
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

const segment = @import("../format/segment.zig");
const entry = @import("../format/entry.zig");
const WriteBatch = @import("../batch/write.zig").WriteBatch;
