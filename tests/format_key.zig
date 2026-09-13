const std = @import("std");
const db = @import("zigritedb");
const Key = db.Key;
const Component = db.Component;
const Region = db.Region;
const testing = std.testing;

test "key bytes" {
    const key: Key = .{ .dimension = 1, .chunk_x = -1, .chunk_z = 32, .component = .subchunk, .subchunk_y = -2 };
    const bytes = try key.encode();
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 255, 255, 255, 255, 32, 0, 0, 0, 0, 254, 255, 255, 255 }, &bytes);
    try testing.expectEqualDeep(key, try Key.decode(&bytes));
}

test "key round trip" {
    for (std.enums.values(Component)) |component| {
        const key: Key = .{
            .dimension = std.math.minInt(i32),
            .chunk_x = std.math.maxInt(i32),
            .chunk_z = std.math.minInt(i32),
            .component = component,
        };
        try testing.expectEqualDeep(key, try Key.decode(&(try key.encode())));
    }
}

test "invalid keys" {
    var bytes = try (Key{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .metadata }).encode();
    for (0..Key.encoded_len) |len| {
        try testing.expectError(error.InvalidLength, Key.decode(bytes[0..len]));
    }
    try testing.expectError(error.InvalidLength, Key.decode(&([_]u8{0} ** 18)));
    for (6..256) |tag| {
        bytes[12] = @intCast(tag);
        try testing.expectError(error.UnknownComponent, Key.decode(&bytes));
    }
    bytes[12] = @intFromEnum(Component.metadata);
    bytes[13] = 1;
    try testing.expectError(error.InvalidSubchunkY, Key.decode(&bytes));
    try testing.expectError(error.InvalidSubchunkY, (Key{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .biomes, .subchunk_y = 1 }).encode());
}

test "negative region boundaries" {
    const coordinates = [_]i32{ -33, -32, -1, 0, 31, 32 };
    const expected = [_]i32{ -2, -1, -1, 0, 0, 1 };
    for (coordinates, expected) |coordinate, region_coordinate| {
        const key: Key = .{ .dimension = -1, .chunk_x = coordinate, .chunk_z = coordinate, .component = .metadata };
        try testing.expectEqualDeep(Region{ .dimension = -1, .x = region_coordinate, .z = region_coordinate }, key.region());
    }
}
