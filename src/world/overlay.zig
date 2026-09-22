const std = @import("std");

const Entry = @import("../format/entry.zig").Entry;
const Key = @import("../format/key.zig").Key;
const world_module = @import("world.zig");
const World = world_module.World;

/// Copy-on-write view that checks overlay values before the base.
pub const OverlayWorld = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base: *World,
    parent: std.Io.Dir,
    name: []const u8,
    options: world_module.Options,
    overlay: World,

    pub const Lookup = union(enum) {
        absent,
        deleted,
        value: []const u8,
    };

    const tombstone = 0;
    const present = 1;
    const inline_len = 8192;

    /// Opens or creates the overlay directory.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, base: *World, parent: std.Io.Dir, name: []const u8, options: world_module.Options) !OverlayWorld {
        return .{
            .allocator = allocator,
            .io = io,
            .base = base,
            .parent = parent,
            .name = name,
            .options = options,
            .overlay = try openOverlay(allocator, io, parent, name, options),
        };
    }

    fn openOverlay(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, name: []const u8, options: world_module.Options) !World {
        parent.createDir(io, name, .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
        const dir = try parent.openDir(io, name, .{ .follow_symlinks = false });
        defer dir.close(io);
        return World.open(allocator, io, dir, options);
    }

    pub fn close(self: *OverlayWorld) !void {
        try self.overlay.close();
    }

    pub fn deinit(self: *OverlayWorld) void {
        self.overlay.deinit();
    }

    /// Drops all overlay changes.
    pub fn reset(self: *OverlayWorld) !void {
        self.overlay.close() catch {};
        self.overlay.deinit();
        try self.parent.deleteTree(self.io, self.name);
        self.overlay = try openOverlay(self.allocator, self.io, self.parent, self.name, self.options);
    }

    /// Looks up a value in the overlay.
    pub fn lookup(self: *OverlayWorld, key: Key, output: []u8) !Lookup {
        var stack: [inline_len]u8 = undefined;
        var heap: []u8 = &.{};
        defer self.allocator.free(heap);
        var buffer: []u8 = &stack;
        const found: ?[]const u8 = while (true) {
            var required: usize = 0;
            break self.overlay.getSized(key, buffer, &required) catch |err| {
                if (err != error.BufferTooSmall) return err;
                self.allocator.free(heap);
                heap = &.{};
                heap = try self.allocator.alloc(u8, required);
                buffer = heap;
                continue;
            };
        };
        const record = found orelse return .absent;

        if (record.len == 0) return error.InvalidOverlayRecord;
        return switch (record[0]) {
            tombstone => if (record.len == 1) .deleted else error.InvalidOverlayRecord,
            present => {
                const value = record[1..];
                if (output.len < value.len) return error.BufferTooSmall;
                @memcpy(output[0..value.len], value);
                return .{ .value = output[0..value.len] };
            },
            else => error.InvalidOverlayRecord,
        };
    }

    /// Reads the overlay first, then the base.
    pub fn get(self: *OverlayWorld, key: Key, output: []u8) !?[]const u8 {
        return switch (try self.lookup(key, output)) {
            .absent => self.base.get(key, output),
            .deleted => null,
            .value => |value| value,
        };
    }

    /// Writes uncompressed changes using the overlay's next batch ID.
    pub fn write(self: *OverlayWorld, entries: []const Entry) !void {
        if (entries.len == 0) return error.EmptyBatch;
        var total: usize = 0;
        for (entries) |item| {
            if (item.header.compression != .none) return error.UnsupportedCompression;
            total += item.value.len + 1;
        }

        const values = try self.allocator.alloc(u8, total);
        defer self.allocator.free(values);
        const marked = try self.allocator.alloc(Entry, entries.len);
        defer self.allocator.free(marked);

        var offset: usize = 0;
        for (entries, marked) |item, *out| {
            const deleted = item.header.kind == .delete;
            const bytes = values[offset..][0 .. (if (deleted) 0 else item.value.len) + 1];
            bytes[0] = if (deleted) tombstone else present;
            if (!deleted) @memcpy(bytes[1..], item.value);
            offset += bytes.len;

            out.* = item;
            out.header.kind = .put;
            out.header.stored_len = @intCast(bytes.len);
            out.header.raw_len = @intCast(bytes.len);
            out.value = bytes;
        }
        _ = try self.overlay.writeNext(marked);
    }
};
