const std = @import("std");

pub const Component = enum(u8) {
    subchunk = 0,
    biomes = 1,
    block_entities = 2,
    entities = 3,
    heightmap = 4,
    metadata = 5,
};

pub const Region = struct { dimension: i32, x: i32, z: i32 };

/// Provisional 17-byte encoding. Non-subchunk keys require subchunk_y == 0.
/// Returned keys and encoded bytes are owned values; no allocation is performed.
pub const Key = struct {
    dimension: i32,
    chunk_x: i32,
    chunk_z: i32,
    component: Component,
    subchunk_y: i32 = 0,

    pub const encoded_len = 17;
    pub const DecodeError = error{ InvalidLength, UnknownComponent, InvalidSubchunkY };

    pub fn encode(self: Key) error{InvalidSubchunkY}![encoded_len]u8 {
        try self.validate();
        var bytes: [encoded_len]u8 = undefined;
        std.mem.writeInt(i32, bytes[0..4], self.dimension, .little);
        std.mem.writeInt(i32, bytes[4..8], self.chunk_x, .little);
        std.mem.writeInt(i32, bytes[8..12], self.chunk_z, .little);
        bytes[12] = @intFromEnum(self.component);
        std.mem.writeInt(i32, bytes[13..17], self.subchunk_y, .little);
        return bytes;
    }

    pub fn decode(bytes: []const u8) DecodeError!Key {
        if (bytes.len != encoded_len) return error.InvalidLength;
        const key: Key = .{
            .dimension = std.mem.readInt(i32, bytes[0..4], .little),
            .chunk_x = std.mem.readInt(i32, bytes[4..8], .little),
            .chunk_z = std.mem.readInt(i32, bytes[8..12], .little),
            .component = std.enums.fromInt(Component, bytes[12]) orelse return error.UnknownComponent,
            .subchunk_y = std.mem.readInt(i32, bytes[13..17], .little),
        };
        try key.validate();
        return key;
    }

    fn validate(self: Key) error{InvalidSubchunkY}!void {
        if (self.component != .subchunk and self.subchunk_y != 0)
            return error.InvalidSubchunkY;
    }

    /// Floor division maps negative chunk coordinates to the correct 32x32 region.
    pub fn region(self: Key) Region {
        return .{ .dimension = self.dimension, .x = @divFloor(self.chunk_x, 32), .z = @divFloor(self.chunk_z, 32) };
    }
};

test "deterministic little-endian encoding" {
    const key: Key = .{ .dimension = 1, .chunk_x = -1, .chunk_z = 32, .component = .subchunk, .subchunk_y = -2 };
    const bytes = try key.encode();
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 255, 255, 255, 255, 32, 0, 0, 0, 0, 254, 255, 255, 255 }, &bytes);
    try std.testing.expectEqualDeep(key, try Key.decode(&bytes));
}

test "all components and extreme coordinates round trip" {
    for (std.enums.values(Component)) |component| {
        const key: Key = .{ .dimension = std.math.minInt(i32), .chunk_x = std.math.maxInt(i32), .chunk_z = std.math.minInt(i32), .component = component };
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
