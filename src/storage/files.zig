const std = @import("std");
const builtin = @import("builtin");

pub fn createSegment(dir: std.Io.Dir, io: std.Io, generation: u64, id: u64) !std.Io.File {
    var buffer: [48]u8 = undefined;
    const name = try segmentName(&buffer, generation, id);

    return dir.createFile(io, name, .{ .read = true, .exclusive = true });
}

pub fn openSegment(dir: std.Io.Dir, io: std.Io, generation: u64, id: u64, writable: bool) !std.Io.File {
    var buffer: [48]u8 = undefined;
    const name = try segmentName(&buffer, generation, id);

    return openRegular(dir, io, name, writable) catch |err| {
        if (err == error.FileNotFound) return error.MissingSegment;
        return err;
    };
}

pub fn removeSegment(dir: std.Io.Dir, io: std.Io, generation: u64, id: u64) !void {
    var buffer: [48]u8 = undefined;
    const name = try segmentName(&buffer, generation, id);
    try dir.deleteFile(io, name);
}
pub fn openManifest(dir: std.Io.Dir, io: std.Io) !std.Io.File {
    return openRegular(dir, io, "MANIFEST", false) catch |err| {
        if (err == error.FileNotFound) return error.MissingManifest;
        return err;
    };
}

fn segmentName(buffer: []u8, generation: u64, id: u64) ![:0]u8 {
    if (generation == 0) return error.InvalidGeneration;
    if (id == 0) return error.InvalidSegmentId;

    return std.fmt.bufPrintZ(buffer, "{x:0>16}-{x:0>16}.segment", .{ generation, id });
}

fn openRegular(dir: std.Io.Dir, io: std.Io, name: [:0]const u8, writable: bool) !std.Io.File {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

    const linux = std.os.linux;
    const flags: linux.O = .{
        .ACCMODE = if (writable) .RDWR else .RDONLY,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .CLOEXEC = true,
        .NOCTTY = true,
    };

    while (true) {
        try io.checkCancel();

        const result = linux.openat(dir.handle, name, flags, 0);
        switch (linux.errno(result)) {
            .SUCCESS => {
                const file: std.Io.File = .{
                    .handle = @intCast(result),
                    .flags = .{ .nonblocking = true },
                };
                errdefer file.close(io);

                if ((try file.stat(io)).kind != .file) return error.NotRegularFile;

                return file;
            },
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .LOOP => return error.SymlinkNotAllowed,
            .ACCES, .PERM => return error.AccessDenied,
            .MFILE, .NFILE => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            else => return error.FileOpenFailed,
        }
    }
}
