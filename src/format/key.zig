const std = @import("std");

pub const Component = enum(u8) {
    subchunk = 0,
    biomes = 1,
    block_entities = 2,
    entities = 3,
    heightmap = 4,
    metadata = 5,
};

pub const Region = struct {
    dimension: i32,
    x: i32,
    z: i32,
};

pub const Key = struct {
    dimension: i32,
    chunk_x: i32,
    chunk_z: i32,
    component: Component,
    subchunk_y: i32 = 0,

    pub const encoded_len = 17;

    pub const DecodeError = error{
        InvalidLength,
        UnknownComponent,
        InvalidSubchunkY,
    };

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

        const component = std.enums.fromInt(Component, bytes[12]) orelse return error.UnknownComponent;

        const key: Key = .{
            .dimension = std.mem.readInt(i32, bytes[0..4], .little),
            .chunk_x = std.mem.readInt(i32, bytes[4..8], .little),
            .chunk_z = std.mem.readInt(i32, bytes[8..12], .little),
            .component = component,
            .subchunk_y = std.mem.readInt(i32, bytes[13..17], .little),
        };

        try key.validate();

        return key;
    }

    fn validate(self: Key) error{InvalidSubchunkY}!void {
        const invalid_subchunk_y = self.component != .subchunk and self.subchunk_y != 0;
        if (invalid_subchunk_y) return error.InvalidSubchunkY;
    }

    pub fn region(self: Key) Region {
        return .{
            .dimension = self.dimension,
            .x = @divFloor(self.chunk_x, 32),
            .z = @divFloor(self.chunk_z, 32),
        };
    }
};
