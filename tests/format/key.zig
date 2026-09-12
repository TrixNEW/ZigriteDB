const std = @import("std");
const db = @import("zigitedb");
const Key = db.Key;
const Component = db.Component;
const Region = db.Region;

test "deterministic little-endian encoding" {
    const key: Key = .{ .dimension = 1, .chunk_x = -1, .chunk_z = 32, .component = .subchunk, .subchunk_y = -2 };
    const bytes = try key.encode();
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 255, 255, 255, 255, 32, 0, 0, 0, 0, 254, 255, 255, 255 }, &bytes);
    try std.testing.expectEqualDeep(key, try Key.decode(&bytes));
}

test "all components and extreme coordinates round trip" {
    for (std.enums.values(Component)) |component| {
        const key: Key = .{
            .dimension = std.math.minInt(i32),
            .chunk_x = std.math.maxInt(i32),
            .chunk_z = std.math.minInt(i32),
            .component = component,
        };
        try std.testing.expectEqualDeep(key, try Key.decode(&(try key.encode())));
    }
}

test "malformed and noncanonical keys are rejected" {
    var bytes = try (Key{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .metadata }).encode();
    for (0..Key.encoded_len) |len| {
        try std.testing.expectError(error.InvalidLength, Key.decode(bytes[0..len]));
    }
    try std.testing.expectError(error.InvalidLength, Key.decode(&([_]u8{0} ** 18)));
    for (6..256) |tag| {
        bytes[12] = @intCast(tag);
        try std.testing.expectError(error.UnknownComponent, Key.decode(&bytes));
    }
    bytes[12] = @intFromEnum(Component.metadata);
    bytes[13] = 1;
    try std.testing.expectError(error.InvalidSubchunkY, Key.decode(&bytes));
    try std.testing.expectError(error.InvalidSubchunkY, (Key{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .biomes, .subchunk_y = 1 }).encode());
}

test "region mapping handles negative boundaries" {
    const coordinates = [_]i32{ -33, -32, -1, 0, 31, 32 };
    const expected = [_]i32{ -2, -1, -1, 0, 0, 1 };
    for (coordinates, expected) |coordinate, region_coordinate| {
        const key: Key = .{ .dimension = -1, .chunk_x = coordinate, .chunk_z = coordinate, .component = .metadata };
        try std.testing.expectEqualDeep(Region{ .dimension = -1, .x = region_coordinate, .z = region_coordinate }, key.region());
    }
}
