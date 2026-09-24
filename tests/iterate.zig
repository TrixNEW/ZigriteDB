const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const item = @import("support/shard.zig").item;

fn at(id: u64, x: i32, z: i32, component: db.Component, y: i32, value: ?[]const u8) db.entry.Entry {
    var result = item(id, x, value);
    result.key.chunk_z = z;
    result.key.component = component;
    result.key.subchunk_y = y;
    return result;
}

test "filters match components and inclusive chunk bounds" {
    const filter: db.KeyFilter = .{ .components = 1 << @intFromEnum(db.Component.biomes), .min_chunk_x = -2, .max_chunk_x = 3 };
    try testing.expect(filter.matches(at(1, -2, 0, .biomes, 0, "").key));
    try testing.expect(filter.matches(at(1, 3, 99, .biomes, 0, "").key));
    try testing.expect(!filter.matches(at(1, 4, 0, .biomes, 0, "").key));
    try testing.expect(!filter.matches(at(1, 0, 0, .subchunk, 0, "").key));
}

test "regions and keys come back sorted and survive compaction between snapshot and read" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_shards = 1 });
    defer world.deinit();

    _ = try world.write(.{ .entries = &.{
        at(1, -1, -33, .subchunk, -4, "low"),
        at(1, -1, -33, .subchunk, 3, "high"),
        at(1, -2, -40, .biomes, 0, "biomes"),
        at(1, -3, -35, .entities, 0, "gone"),
    } });
    _ = try world.write(.{ .entries = &.{at(2, -3, -35, .entities, 0, null)} });
    _ = try world.write(.{ .entries = &.{at(1, 40, 5, .metadata, 0, "east")} });

    const regions = try world.regions(testing.allocator);
    defer testing.allocator.free(regions);
    try testing.expectEqualSlices(db.Region, &.{
        .{ .dimension = 0, .x = -1, .z = -2 },
        .{ .dimension = 0, .x = 1, .z = 0 },
    }, regions);

    const west = try world.keys(regions[0], testing.allocator, .{});
    defer testing.allocator.free(west);
    try testing.expectEqual(@as(usize, 3), west.len);
    try testing.expectEqual(at(0, -2, -40, .biomes, 0, "").key, west[0]);
    try testing.expectEqual(at(0, -1, -33, .subchunk, -4, "").key, west[1]);
    try testing.expectEqual(at(0, -1, -33, .subchunk, 3, "").key, west[2]);

    _ = try world.compact(regions[0]);
    var output: [16]u8 = undefined;
    try testing.expectEqualStrings("high", (try world.get(west[2], &output)).?);

    const biomes = try world.keys(regions[0], testing.allocator, .{ .components = 1 << @intFromEnum(db.Component.biomes) });
    defer testing.allocator.free(biomes);
    try testing.expectEqual(@as(usize, 1), biomes.len);

    const missing = try world.keys(.{ .dimension = 1, .x = 0, .z = 0 }, testing.allocator, .{});
    defer testing.allocator.free(missing);
    try testing.expectEqual(@as(usize, 0), missing.len);

    const range = try world.keysInRange(testing.allocator, 0, .{ .min_chunk_x = -1, .max_chunk_x = 40, .min_chunk_z = -34, .max_chunk_z = 5 });
    defer testing.allocator.free(range);
    try testing.expectEqual(@as(usize, 3), range.len);
    try testing.expectEqual(at(0, 40, 5, .metadata, 0, "").key, range[2]);

    try testing.expectError(error.RangeTooLarge, world.keysInRange(testing.allocator, 0, .{}));
    try world.close();
}
