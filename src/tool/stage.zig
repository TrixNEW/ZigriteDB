//! Builds a directory under a temporary name so an interrupted run never looks finished.
const std = @import("std");

const File = @import("../io/file.zig").File;

pub const suffix = ".zigrite-partial";

/// Says what went wrong in words, since an error name alone can't point at the record or file.
pub const Problem = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Problem) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn set(self: ?*Problem, comptime format: []const u8, args: anytype) void {
        const problem = self orelse return;
        if (problem.len != 0) return;
        problem.len = if (std.fmt.bufPrint(&problem.buffer, format, args)) |written| written.len else |_| blk: {
            @memcpy(problem.buffer[problem.buffer.len - 3 ..], "...");
            break :blk problem.buffer.len;
        };
    }
};

pub const Staged = struct {
    io: std.Io,
    // The destination's own parent, so the rename and its sync land in the same directory.
    parent: std.Io.Dir,
    name_buffer: [std.fs.max_name_bytes]u8,
    name_len: usize,
    temporary: [std.fs.max_name_bytes]u8,
    temporary_len: usize,
    dir: std.Io.Dir,
    published: bool = false,

    pub fn begin(io: std.Io, base: std.Io.Dir, destination: []const u8) !Staged {
        const trimmed = std.mem.trimEnd(u8, destination, "/");
        const leaf = std.fs.path.basename(trimmed);
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.InvalidArgument;
        const parent = try base.openDir(io, std.fs.path.dirname(trimmed) orelse ".", .{ .iterate = true });
        errdefer parent.close(io);
        if (parent.statFile(io, leaf, .{ .follow_symlinks = false })) |_| {
            return error.PathAlreadyExists;
        } else |err| if (err != error.FileNotFound) return err;

        var self: Staged = .{ .io = io, .parent = parent, .name_buffer = undefined, .name_len = leaf.len, .temporary = undefined, .temporary_len = 0, .dir = undefined };
        if (leaf.len > self.name_buffer.len) return error.NameTooLong;
        @memcpy(self.name_buffer[0..leaf.len], leaf);
        const temporary = try std.fmt.bufPrint(&self.temporary, "{s}{s}", .{ leaf, suffix });
        self.temporary_len = temporary.len;
        parent.deleteTree(io, temporary) catch |err| if (err != error.FileNotFound) return err;
        try parent.createDir(io, temporary, .default_dir);
        errdefer parent.deleteTree(io, temporary) catch {};
        self.dir = try parent.openDir(io, temporary, .{ .iterate = true, .follow_symlinks = false });
        return self;
    }

    pub fn name(self: *const Staged) []const u8 {
        return self.temporary[0..self.temporary_len];
    }

    pub fn publish(self: *Staged) !void {
        try syncTree(self.io, self.dir);
        const destination = self.name_buffer[0..self.name_len];
        // Something may have appeared there since begin, and rename would replace an empty directory.
        if (self.parent.statFile(self.io, destination, .{ .follow_symlinks = false })) |_| {
            return error.PathAlreadyExists;
        } else |err| if (err != error.FileNotFound) return err;
        try self.parent.rename(self.name(), self.parent, destination, self.io);
        self.published = true;
        try syncDir(self.io, self.parent);
    }

    pub fn deinit(self: *Staged) void {
        self.dir.close(self.io);
        if (!self.published) self.parent.deleteTree(self.io, self.name()) catch {};
        self.parent.close(self.io);
    }
};

pub fn syncDir(io: std.Io, dir: std.Io.Dir) !void {
    try (File{ .handle = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }, .io = io }).sync();
}

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
    try syncDir(io, dir);
}

/// Copies regular files and directories, refusing symlinks and anything else so nothing outside the tree is pulled in.
pub fn copyTree(io: std.Io, from: std.Io.Dir, to: std.Io.Dir, skip: []const []const u8) !u64 {
    var copied: u64 = 0;
    var iterator = from.iterate();
    entries: while (try iterator.next(io)) |entry| {
        for (skip) |name| if (std.mem.eql(u8, entry.name, name)) continue :entries;
        switch (entry.kind) {
            .file => {
                try from.copyFile(entry.name, to, entry.name, io, .{});
                copied += 1;
            },
            .directory => {
                try to.createDir(io, entry.name, .default_dir);
                const child_from = try from.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child_from.close(io);
                const child_to = try to.openDir(io, entry.name, .{});
                defer child_to.close(io);
                copied += try copyTree(io, child_from, child_to, &.{});
            },
            else => return error.UnsupportedFileType,
        }
    }
    return copied;
}
