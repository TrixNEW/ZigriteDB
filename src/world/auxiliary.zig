//! Byte keys for everything that isn't chunk data. Keys hash into buckets stored as
//! records in a reserved dimension.
const std = @import("std");

const lock = @import("../lock.zig");
const key_format = @import("../format/key.zig");
const Key = key_format.Key;
const Region = key_format.Region;
const record = @import("../format/record.zig");
const World = @import("world.zig").World;
const parseKey = @import("../bedrock/convert.zig").parseKey;

pub const dimension = std.math.minInt(i32);

pub fn isAux(region: Region) bool {
    return region.dimension == dimension;
}

// 16 regions of 1024 slots x 64 components, under the default key limit.
fn bucket(key: []const u8) Key {
    const h = std.hash.Wyhash.hash(0x617578, key);
    const slot: i32 = @intCast((h >> 4) & 1023);
    return .{
        .dimension = dimension,
        .chunk_x = @as(i32, @intCast(h & 3)) * 32 + @mod(slot, 32),
        .chunk_z = @as(i32, @intCast((h >> 2) & 3)) * 32 + @divFloor(slot, 32),
        .component = @enumFromInt(@as(u8, @intCast((h >> 14) & 63))),
    };
}

/// `u32 key length, key, u32 value length, value`, sorted by key.
pub const Entries = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn next(self: *Entries) !?struct { []const u8, []const u8 } {
        if (self.at == self.bytes.len) return null;
        const k = try self.take();
        const v = try self.take();
        return .{ k, v };
    }

    fn take(self: *Entries) ![]const u8 {
        if (self.bytes.len - self.at < 4) return error.InvalidAuxBucket;
        const len = std.mem.readInt(u32, self.bytes[self.at..][0..4], .little);
        self.at += 4;
        if (self.bytes.len - self.at < len) return error.InvalidAuxBucket;
        defer self.at += len;
        return self.bytes[self.at..][0..len];
    }
};

fn readBucket(world: *World, allocator: std.mem.Allocator, key: Key) !?[]u8 {
    var buffer: []u8 = &.{};
    while (true) {
        var required: usize = 0;
        const found = world.getSized(key, buffer, &required) catch |err| {
            if (err != error.BufferTooSmall) {
                allocator.free(buffer);
                return err;
            }
            allocator.free(buffer);
            buffer = &.{};
            buffer = try allocator.alloc(u8, required);
            continue;
        };
        if (found) |value| return buffer[0..value.len];
        allocator.free(buffer);
        return null;
    }
}

/// Chunk-shaped keys are chunk records.
pub fn get(world: *World, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    if (parseKey(key)) |chunk| return readBucket(world, allocator, chunk);
    const bytes = (try readBucket(world, allocator, bucket(key))) orelse return null;
    defer allocator.free(bytes);
    var entries: Entries = .{ .bytes = bytes };
    while (try entries.next()) |entry| {
        if (std.mem.eql(u8, entry[0], key)) return try allocator.dupe(u8, entry[1]);
    }
    return null;
}

/// Null deletes the key.
pub fn put(world: *World, allocator: std.mem.Allocator, key: []const u8, value: ?[]const u8) !void {
    if (key.len > std.math.maxInt(u32)) return error.InvalidArgument;
    if (parseKey(key)) |chunk| {
        _ = try world.write(.{ .entries = &.{.{ .key = chunk, .value = value }} });
        return;
    }
    const target = bucket(key);
    lock.lockUncancelable(&world.aux_mutex, world.io);
    defer world.aux_mutex.unlock(world.io);
    const old = try readBucket(world, allocator, target);
    defer if (old) |bytes| allocator.free(bytes);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var placed = false;
    var entries: Entries = .{ .bytes = old orelse &.{} };
    while (try entries.next()) |entry| {
        const order = std.mem.order(u8, entry[0], key);
        if (order == .gt and !placed) {
            if (value) |v| try append(&out, allocator, key, v);
            placed = true;
        }
        if (order == .eq) continue;
        try append(&out, allocator, entry[0], entry[1]);
    }
    if (!placed) if (value) |v| try append(&out, allocator, key, v);
    if (out.items.len > record.max_value_len) return error.BatchTooLarge;
    if (old == null and out.items.len == 0) return;
    _ = try world.write(.{ .entries = &.{.{ .key = target, .value = if (out.items.len == 0) null else out.items }} });
}

fn append(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(key.len), .little);
    try out.appendSlice(allocator, &len);
    try out.appendSlice(allocator, key);
    std.mem.writeInt(u32, &len, @intCast(value.len), .little);
    try out.appendSlice(allocator, &len);
    try out.appendSlice(allocator, value);
}

pub fn each(world: *World, allocator: std.mem.Allocator, context: anytype, comptime visit: anytype) !void {
    const regions = try world.regions(allocator);
    defer allocator.free(regions);
    for (regions) |region| {
        if (!isAux(region)) continue;
        const keys = try world.keys(region, allocator, .{});
        defer allocator.free(keys);
        for (keys) |k| {
            const bytes = (try readBucket(world, allocator, k)) orelse continue;
            defer allocator.free(bytes);
            var entries: Entries = .{ .bytes = bytes };
            while (try entries.next()) |entry| try visit(context, entry[0], entry[1]);
        }
    }
}

test "keys share buckets without losing each other" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    var world = try World.open(allocator, std.testing.io, tmp.dir, .{});
    defer world.deinit();
    var names: [300][16]u8 = undefined;
    for (&names, 0..) |*name, i| _ = try std.fmt.bufPrint(name, "player_{d:0>9}", .{i});
    for (names, 0..) |name, i| try put(&world, allocator, &name, if (i % 7 == 0) "" else &name);
    for (names[0..100]) |name| try put(&world, allocator, &name, null);
    try put(&world, allocator, "missing", null);
    for (names, 0..) |name, i| {
        const found = try get(&world, allocator, &name);
        defer if (found) |f| allocator.free(f);
        if (i < 100) try std.testing.expectEqual(null, found) else try std.testing.expectEqualStrings(if (i % 7 == 0) "" else &name, found.?);
    }
    const Count = struct {
        n: usize = 0,
        fn visit(self: *@This(), _: []const u8, _: []const u8) !void {
            self.n += 1;
        }
    };
    var count: Count = .{};
    try each(&world, allocator, &count, Count.visit);
    try std.testing.expectEqual(@as(usize, 200), count.n);
    try world.close();
}

test "chunk-shaped keys go to their chunk record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    var world = try World.open(allocator, std.testing.io, tmp.dir, .{});
    defer world.deinit();
    try put(&world, allocator, "player_10", "nbt");
    const found = (try get(&world, allocator, "player_10")).?;
    defer allocator.free(found);
    try std.testing.expectEqualStrings("nbt", found);
    var output: [8]u8 = undefined;
    try std.testing.expectEqualStrings("nbt", (try world.get(parseKey("player_10").?, &output)).?);
    try put(&world, allocator, "player_10", null);
    try std.testing.expectEqual(null, try get(&world, allocator, "player_10"));
    try world.close();
}
