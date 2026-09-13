const std = @import("std");
const builtin = @import("builtin");

const manifest = @import("../format/manifest.zig");
const storage = @import("../io/file.zig");

pub const supported = builtin.os.tag == .linux;

pub const Directory = struct {
    io: std.Io,
    dir: std.Io.Dir,
    temporary: ?std.Io.File = null,
    state: State = .idle,

    const State = enum {
        idle,
        written,
        synced,
        replaced,
        failed,
        closed,
    };

    pub fn init(parent: std.Io.Dir, io: std.Io) !Directory {
        if (!supported) return error.UnsupportedPlatform;

        const dir = try parent.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io);

        var self: Directory = .{ .dir = dir, .io = io };
        if (!try self.directoryFile().tryLock(io, .exclusive)) return error.DirectoryBusy;

        try self.directoryFile().sync(io);

        return self;
    }

    pub fn deinit(self: *Directory) void {
        if (self.state == .closed) return;

        if (self.temporary) |file| file.close(self.io);
        self.dir.close(self.io);
        self.temporary = null;
        self.state = .closed;
    }

    pub fn writeTemporary(self: *Directory, bytes: []const u8) !void {
        if (self.state != .idle) return error.InvalidPublicationState;

        var ids: [manifest.max_segments]u64 = undefined;
        _ = try manifest.decode(bytes, &ids);

        errdefer self.state = .failed;

        const file = try self.dir.createFile(self.io, "MANIFEST.tmp", .{ .exclusive = true });
        self.temporary = file;

        try (storage.File{ .handle = file, .io = self.io }).writeAll(bytes, 0);
        self.state = .written;
    }

    pub fn syncTemporary(self: *Directory) !void {
        if (self.state != .written) return error.InvalidPublicationState;
        errdefer self.state = .failed;

        try self.temporary.?.sync(self.io);
        try self.directoryFile().sync(self.io);
        self.state = .synced;
    }

    pub fn replaceManifest(self: *Directory) !void {
        if (self.state != .synced) return error.InvalidPublicationState;
        errdefer self.state = .failed;

        self.temporary.?.close(self.io);
        self.temporary = null;

        try self.dir.rename("MANIFEST.tmp", self.dir, "MANIFEST", self.io);
        self.state = .replaced;
    }

    pub fn syncDirectory(self: *Directory) !void {
        if (self.state != .replaced) return error.InvalidPublicationState;
        errdefer self.state = .failed;

        try self.directoryFile().sync(self.io);
        self.state = .idle;
    }

    fn directoryFile(self: *const Directory) std.Io.File {
        return .{
            .handle = self.dir.handle,
            .flags = .{ .nonblocking = false },
        };
    }
};
