const std = @import("std");

const key_format = @import("../format/key.zig");
const Component = key_format.Component;
const Key = key_format.Key;
const WriteBatch = @import("../batch/write.zig").WriteBatch;
const Entry = @import("../batch/write.zig").Entry;
const frame = @import("../format/frame.zig");
const World = @import("../world/world.zig").World;
const aux = @import("../world/aux.zig");
const stage = @import("../tool/stage.zig");
const leveldb = @import("leveldb.zig");

pub const files_dir = "bedrock";

pub const Result = struct {
    chunk_records: u64 = 0,
    aux_records: u64 = 0,
    bytes: u64 = 0,
};

fn chunkTag(tag: u8) bool {
    return (tag >= 0x2b and tag <= 0x41) or tag == 0x76;
}

/// Exact Bedrock layout only, so mapping back is lossless.
pub fn parseKey(bytes: []const u8) ?Key {
    if ((bytes.len == 12 or bytes.len == 16) and std.mem.eql(u8, bytes[0..4], "digp")) {
        const dim: i32 = if (bytes.len == 16) std.mem.readInt(i32, bytes[12..16], .little) else 0;
        if (bytes.len == 16 and dim == 0) return null;
        return .{ .dimension = dim, .chunk_x = std.mem.readInt(i32, bytes[4..8], .little), .chunk_z = std.mem.readInt(i32, bytes[8..12], .little), .component = .actor_digest };
    }
    const with_dim = bytes.len == 13 or bytes.len == 14;
    if (!with_dim and bytes.len != 9 and bytes.len != 10) return null;
    const tag_at: usize = if (with_dim) 12 else 8;
    const tag = bytes[tag_at];
    const has_y = bytes.len == tag_at + 2;
    if (!chunkTag(tag) or has_y != (tag == @intFromEnum(Component.subchunk))) return null;
    const dim: i32 = if (with_dim) std.mem.readInt(i32, bytes[8..12], .little) else 0;
    if (with_dim and dim == 0) return null;
    return .{
        .dimension = dim,
        .chunk_x = std.mem.readInt(i32, bytes[0..4], .little),
        .chunk_z = std.mem.readInt(i32, bytes[4..8], .little),
        .component = @enumFromInt(tag),
        .subchunk_y = if (has_y) @as(i8, @bitCast(bytes[tag_at + 1])) else 0,
    };
}

pub fn levelKey(key: Key, out: *[16]u8) []const u8 {
    var len: usize = 0;
    if (key.component == .actor_digest) {
        @memcpy(out[0..4], "digp");
        len = 4;
    }
    std.mem.writeInt(i32, out[len..][0..4], key.chunk_x, .little);
    std.mem.writeInt(i32, out[len + 4 ..][0..4], key.chunk_z, .little);
    len += 8;
    if (key.dimension != 0) {
        std.mem.writeInt(i32, out[len..][0..4], key.dimension, .little);
        len += 4;
    }
    if (key.component == .actor_digest) return out[0..len];
    out[len] = @intFromEnum(key.component);
    len += 1;
    if (key.component == .subchunk) {
        out[len] = @bitCast(@as(i8, @intCast(key.subchunk_y)));
        len += 1;
    }
    return out[0..len];
}

pub fn import(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, source: []const u8, destination: []const u8) !Result {
    const world_dir = try parent.openDir(io, source, .{ .iterate = true });
    defer world_dir.close(io);
    const db_dir = try world_dir.openDir(io, "db", .{ .iterate = true });
    defer db_dir.close(io);
    var staged = try stage.Staged.begin(io, parent, destination);
    defer staged.deinit();

    try staged.dir.createDir(io, files_dir, .default_dir);
    {
        const files = try staged.dir.openDir(io, files_dir, .{});
        defer files.close(io);
        try copyTree(io, world_dir, files, true);
    }

    var result: Result = .{};
    {
        // LevelDB order hops between regions, so keep them all open.
        var world = try World.open(allocator, io, staged.dir, .{ .max_open_regions = 1024, .region = .{ .batch_buffer_size = frame.max_bytes + frame.header_len, .compact_live_percent = 0 } });
        defer world.deinit();
        var reader = try leveldb.Reader.open(allocator, io, db_dir);
        defer reader.deinit();
        var batch: Pending = .{ .allocator = allocator };
        defer batch.deinit();
        while (try reader.next()) |item| {
            const key, const value = item;
            result.bytes += value.len;
            if (parseKey(key)) |chunk_key| {
                try batch.add(&world, chunk_key, value);
                result.chunk_records += 1;
            } else {
                try aux.put(&world, allocator, key, value);
                result.aux_records += 1;
            }
        }
        try batch.flush(&world);
        try world.close();
    }
    try staged.publish();
    return result;
}

const Pending = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator = undefined,
    started: bool = false,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    bytes: usize = 0,

    const target = 512 * 1024;

    fn deinit(self: *Pending) void {
        if (self.started) self.arena.deinit();
        self.entries.deinit(self.allocator);
    }

    fn add(self: *Pending, world: *World, key: Key, value: []const u8) !void {
        if (self.entries.items.len != 0) {
            const first = self.entries.items[0].key;
            const same = first.dimension == key.dimension and first.chunk_x == key.chunk_x and first.chunk_z == key.chunk_z;
            if (!same or self.bytes + value.len > target or self.entries.items.len == frame.max_records) try self.flush(world);
        }
        if (!self.started) {
            self.arena = .init(self.allocator);
            self.started = true;
        }
        try self.entries.append(self.allocator, .{ .key = key, .value = try self.arena.allocator().dupe(u8, value) });
        self.bytes += value.len;
    }

    fn flush(self: *Pending, world: *World) !void {
        if (self.entries.items.len == 0) return;
        _ = try world.write(.{ .entries = self.entries.items });
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.bytes = 0;
    }
};

const Exported = struct {
    key: []const u8,
    source: union(enum) { chunk: Key, aux: Key },

    fn lessThan(_: void, a: Exported, b: Exported) bool {
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

pub fn exportWorld(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, source: []const u8, destination: []const u8, compression: leveldb.Compression) !Result {
    const source_dir = try parent.openDir(io, source, .{ .iterate = true });
    defer source_dir.close(io);
    var staged = try stage.Staged.begin(io, parent, destination);
    defer staged.deinit();
    if (source_dir.openDir(io, files_dir, .{ .iterate = true })) |files| {
        defer files.close(io);
        try copyTree(io, files, staged.dir, false);
    } else |err| if (err != error.FileNotFound) return err;

    var result: Result = .{};
    {
        var world = try World.open(allocator, io, source_dir, .{ .max_open_regions = 1024 });
        defer world.deinit();
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const keys = arena.allocator();

        var list: std.ArrayListUnmanaged(Exported) = .empty;
        const regions = try world.regions(allocator);
        defer allocator.free(regions);
        for (regions) |region| {
            const found = try world.keys(region, allocator, .{});
            defer allocator.free(found);
            if (aux.isAux(region)) {
                for (found) |bucket| {
                    const bytes = (try world.get(bucket, try buffer(&world, keys, bucket))) orelse continue;
                    var entries: aux.Entries = .{ .bytes = bytes };
                    while (try entries.next()) |entry| try list.append(keys, .{ .key = entry[0], .source = .{ .aux = bucket } });
                }
                continue;
            }
            for (found) |key| {
                var bytes: [16]u8 = undefined;
                try list.append(keys, .{ .key = try keys.dupe(u8, levelKey(key, &bytes)), .source = .{ .chunk = key } });
            }
        }
        std.mem.sort(Exported, list.items, {}, Exported.lessThan);

        try staged.dir.createDir(io, "db", .default_dir);
        const db_dir = try staged.dir.openDir(io, "db", .{});
        defer db_dir.close(io);
        var writer = try leveldb.Writer.init(allocator, io, db_dir, compression);
        defer writer.deinit();
        var value: std.ArrayListUnmanaged(u8) = .empty;
        defer value.deinit(allocator);
        for (list.items) |item| {
            const bytes = switch (item.source) {
                .chunk => |key| blk: {
                    const size = (try world.valueSize(key)) orelse return error.FileChanged;
                    try value.resize(allocator, size);
                    result.chunk_records += 1;
                    break :blk (try world.get(key, value.items)).?;
                },
                // Aux keys point into their bucket, still held by the arena.
                .aux => blk: {
                    result.aux_records += 1;
                    break :blk auxValue(item.key);
                },
            };
            result.bytes += bytes.len;
            try writer.add(item.key, bytes);
        }
        try writer.finish();
        try world.close();
    }
    try staged.publish();
    return result;
}

fn buffer(world: *World, allocator: std.mem.Allocator, key: Key) ![]u8 {
    return allocator.alloc(u8, (try world.valueSize(key)) orelse 0);
}

fn auxValue(key: []const u8) []const u8 {
    const after = key.ptr + key.len;
    const len = std.mem.readInt(u32, after[0..4], .little);
    return (after + 4)[0..len];
}

fn copyTree(io: std.Io, from: std.Io.Dir, to: std.Io.Dir, skip_db: bool) !void {
    var iterator = from.iterate();
    while (try iterator.next(io)) |entry| {
        if (skip_db and std.mem.eql(u8, entry.name, "db")) continue;
        switch (entry.kind) {
            .file => try from.copyFile(entry.name, to, entry.name, io, .{}),
            .directory => {
                try to.createDir(io, entry.name, .default_dir);
                const child_from = try from.openDir(io, entry.name, .{ .iterate = true });
                defer child_from.close(io);
                const child_to = try to.openDir(io, entry.name, .{});
                defer child_to.close(io);
                try copyTree(io, child_from, child_to, false);
            },
            else => return error.UnsupportedFileType,
        }
    }
}

test "chunk keys map both ways and everything else is left alone" {
    var out: [16]u8 = undefined;
    const cases = [_][]const u8{
        &.{ 1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff, 0x2c },
        &.{ 1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff, 0x2f, 0xfc },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0x2b },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 0x2f, 7 },
        "digp" ++ &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0 },
        "digp" ++ &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0 },
    };
    for (cases) |bytes| try std.testing.expectEqualSlices(u8, bytes, levelKey(parseKey(bytes).?, &out));
    const others = [_][]const u8{
        "~local_player",
        "BiomeData",
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0x2c, 9 },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0x2f },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0x2c },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0x99 },
        "digp" ++ &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 },
        "actorprefix" ++ &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 },
    };
    for (others) |bytes| try std.testing.expectEqual(null, parseKey(bytes));
}
