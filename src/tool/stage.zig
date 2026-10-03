//! Builds a directory under a temporary name and renames it into place once complete,
//! so an interrupted conversion never leaves something that looks finished.
const std = @import("std");

const File = @import("../io/file.zig").File;

pub const suffix = ".zigrite-partial";

pub const Staged = struct {
    io: std.Io,
    parent: std.Io.Dir,
    destination: []const u8,
    temporary: [std.fs.max_name_bytes]u8,
    temporary_len: usize,
    dir: std.Io.Dir,
    published: bool = false,

    /// The destination must not exist; leftovers of an earlier interrupted run are removed.
    pub fn begin(io: std.Io, parent: std.Io.Dir, destination: []const u8) !Staged {
        if (parent.statFile(io, destination, .{ .follow_symlinks = false })) |_| {
            return error.PathAlreadyExists;
        } else |err| if (err != error.FileNotFound) return err;
        var self: Staged = .{ .io = io, .parent = parent, .destination = destination, .temporary = undefined, .temporary_len = 0, .dir = undefined };
        const temporary = try std.fmt.bufPrint(&self.temporary, "{s}{s}", .{ destination, suffix });
        self.temporary_len = temporary.len;
        parent.deleteTree(io, temporary) catch |err| if (err != error.FileNotFound) return err;
        try parent.createDir(io, temporary, .default_dir);
        self.dir = try parent.openDir(io, temporary, .{ .iterate = true, .follow_symlinks = false });
        return self;
    }

    pub fn name(self: *const Staged) []const u8 {
        return self.temporary[0..self.temporary_len];
    }

    /// Syncs everything written, then makes the destination appear in one rename.
    pub fn publish(self: *Staged) !void {
        try syncTree(self.io, self.dir);
        try self.parent.rename(self.name(), self.parent, self.destination, self.io);
        // The caller's handle may be path-only, which cannot be synced.
        const parent = try self.parent.openDir(self.io, ".", .{ .iterate = true });
        defer parent.close(self.io);
        try (File{ .handle = .{ .handle = parent.handle, .flags = .{ .nonblocking = false } }, .io = self.io }).sync();
        self.published = true;
    }

    pub fn deinit(self: *Staged) void {
        self.dir.close(self.io);
        if (!self.published) self.parent.deleteTree(self.io, self.name()) catch {};
    }
};

/// Fsyncs every file and directory below `dir`, and `dir` itself.
pub fn syncTree(io: std.Io, dir: std.Io.Dir) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| switch (entry.kind) {
        .file => {
            const file = try dir.openFile(io, entry.name, .{});
            defer file.close(io);
            try (File{ .handle = file, .io = io }).sync();
        },
        .directory => {
            const child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            try syncTree(io, child);
        },
        else => {},
    };
    try (File{ .handle = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }, .io = io }).sync();
}
