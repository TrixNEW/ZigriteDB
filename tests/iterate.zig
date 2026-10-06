const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const batch = @import("support/region.zig").batch;

fn at(x: i32, z: i32, component: db.Component, y: i32) db.Key {
    return .{ .dimension = 0, .chunk_x = x, .chunk_z = z, .component = component, .subchunk_y = y };
}

fn entry(x: i32, z: i32, component: db.Component, y: i32, value: ?[]const u8) db.Entry {
    return .{ .key = at(x, z, component, y), .value = value };
}

test "filters match components and inclusive chunk bounds" {
    var filter: db.KeyFilter = .only(&.{.data3d});
    filter.min_chunk_x = -2;
    filter.max_chunk_x = 3;
    try testing.expect(filter.matches(at(-2, 0, .data3d, 0)));
    try testing.expect(filter.matches(at(3, 99, .data3d, 0)));
    try testing.expect(!filter.matches(at(4, 0, .data3d, 0)));
    try testing.expect(!filter.matches(at(0, 0, .subchunk, 0)));
    try testing.expect((db.KeyFilter{}).matches(at(0, 0, @enumFromInt(0xff), 0)));
}

test "regions and keys come back sorted and survive compaction between snapshot and read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_regions = 1 });
    defer world.deinit();

    _ = try world.write(batch(1, &.{
        entry(-1, -33, .subchunk, -4, "low"),
        entry(-1, -33, .subchunk, 3, "high"),
        entry(-2, -40, .data3d, 0, "biomes"),
        entry(-3, -35, .entities, 0, "gone"),
    }));
    _ = try world.write(batch(2, &.{entry(-3, -35, .entities, 0, null)}));
    _ = try world.write(batch(1, &.{entry(40, 5, .version, 0, "east")}));

    const regions = try world.regions(testing.allocator);
    defer testing.allocator.free(regions);
    try testing.expectEqualSlices(db.Region, &.{
        .{ .dimension = 0, .x = -1, .z = -2 },
        .{ .dimension = 0, .x = 1, .z = 0 },
    }, regions);

    const west = try world.keys(regions[0], testing.allocator, .{});
    defer testing.allocator.free(west);
    try testing.expectEqual(@as(usize, 3), west.len);
    try testing.expectEqual(at(-2, -40, .data3d, 0), west[0]);
    try testing.expectEqual(at(-1, -33, .subchunk, -4), west[1]);
    try testing.expectEqual(at(-1, -33, .subchunk, 3), west[2]);

    _ = try world.compact(regions[0]);
    var output: [16]u8 = undefined;
    try testing.expectEqualStrings("high", (try world.get(west[2], &output)).?);

    const biomes = try world.keys(regions[0], testing.allocator, .only(&.{.data3d}));
    defer testing.allocator.free(biomes);
    try testing.expectEqual(@as(usize, 1), biomes.len);

    const missing = try world.keys(.{ .dimension = 1, .x = 0, .z = 0 }, testing.allocator, .{});
    defer testing.allocator.free(missing);
    try testing.expectEqual(@as(usize, 0), missing.len);

    const range = try world.keysInRange(testing.allocator, 0, .{ .min_chunk_x = -1, .max_chunk_x = 40, .min_chunk_z = -34, .max_chunk_z = 5 });
    defer testing.allocator.free(range);
    try testing.expectEqual(@as(usize, 3), range.len);
    try testing.expectEqual(at(40, 5, .version, 0), range[2]);

    try testing.expectError(error.RangeTooLarge, world.keysInRange(testing.allocator, 0, .{}));
    try world.close();
}
